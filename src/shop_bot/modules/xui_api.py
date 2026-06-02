import uuid
from datetime import datetime, timedelta
import logging
import secrets
import hashlib
from urllib.parse import urlparse, quote, urlunparse
from typing import List, Dict

from py3xui import Api, Client, Inbound

from shop_bot.data_manager.database import get_host, get_key_by_email, get_setting

logger = logging.getLogger(__name__)

def _client_attr(client, *names):
    for name in names:
        try:
            value = getattr(client, name)
        except Exception:
            value = None
        if value not in (None, ""):
            return value
        try:
            value = client.get(name)
        except Exception:
            value = None
        if value not in (None, ""):
            return value
    return None

def _client_identifier(client, protocol: str) -> str | None:
    proto = (protocol or "").strip().lower()
    if proto == "trojan":
        value = _client_attr(client, "password", "id", "email")
    elif proto == "shadowsocks":
        value = _client_attr(client, "email", "password", "id")
    else:
        value = _client_attr(client, "id", "password", "email")
    return str(value) if value not in (None, "") else None

def _protocol_client_secret(protocol: str) -> str:
    proto = (protocol or "").strip().lower()
    if proto == "trojan":
        return secrets.token_urlsafe(18).replace("-", "").replace("_", "")
    return str(uuid.uuid4())

def _hostname_from_url(host_url: str) -> str:
    parsed = urlparse(host_url if "://" in host_url else f"https://{host_url}")
    return (parsed.hostname or "").strip()

def _public_https_origin(host_url: str, domain: str | None = None) -> str:
    hostname = (domain or _hostname_from_url(host_url)).strip()
    if not hostname:
        return ""
    return f"https://{hostname}"

def _public_subscription_base(host_url: str, domain: str | None) -> str:
    hostname = (domain or _hostname_from_url(host_url)).strip()
    if not hostname:
        return ""
    return f"https://{hostname}/sub"

def _connect_signature_payload(key_id: int, client_uuid: str, key_email: str, host_name: str | None = None) -> str:
    return f"{int(key_id)}:{client_uuid}:{key_email}:{(host_name or '').strip()}"

def get_connect_signature(key_id: int, client_uuid: str, key_email: str, host_name: str | None = None) -> str:
    payload = _connect_signature_payload(key_id, client_uuid, key_email, host_name)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

def build_connect_page_url(
    key_id: int,
    client_uuid: str,
    key_email: str,
    host_name: str | None = None,
    host_url: str | None = None,
) -> str | None:
    if not key_id or not client_uuid or not key_email:
        return None

    resolved_host_url = (host_url or "").strip()
    if not resolved_host_url and host_name:
        host_row = get_host(host_name)
        if host_row:
            resolved_host_url = (host_row.get("host_url") or "").strip()

    origin = _public_https_origin(resolved_host_url, (get_setting("domain") or "").strip() or None)
    if not origin:
        return None

    sig = get_connect_signature(key_id, client_uuid, key_email, host_name)
    return f"{origin}/connect/{int(key_id)}?sig={sig}"

def build_connect_page_url_for_key(key_data: dict | None) -> str | None:
    if not key_data:
        return None
    return build_connect_page_url(
        key_id=int(key_data.get("key_id") or 0),
        client_uuid=str(key_data.get("xui_client_uuid") or "").strip(),
        key_email=str(key_data.get("key_email") or "").strip(),
        host_name=key_data.get("host_name"),
    )

def _normalize_subscription_url(link: str, host_url: str, domain: str | None) -> str:
    normalized = (link or "").strip()
    if not normalized:
        return normalized

    # Если схема не указана (например, sub.example.com/{token}) — считаем https.
    if "://" not in normalized and not normalized.startswith("/"):
        normalized = f"https://{normalized.lstrip('/')}"

    parsed = urlparse(normalized)
    if parsed.scheme not in ("http", "https"):
        return normalized
    if parsed.scheme == "https":
        return normalized

    # Поднимаем http -> https, если ссылка ведет на тот же домен, что и панель/настройка domain.
    host_parsed = urlparse(host_url if "://" in host_url else f"https://{host_url}")
    panel_host = (host_parsed.hostname or "").strip().lower()
    cfg_domain = (domain or "").strip().lower()
    link_host = (parsed.hostname or "").strip().lower()

    # Принудительно поднимаем до https только когда порт не задан явно.
    # Для нестандартных портов (например :2096) https может быть не настроен.
    if link_host and (link_host == panel_host or (cfg_domain and link_host == cfg_domain)):
        if parsed.port is None:
            return parsed._replace(scheme="https").geturl()

    return normalized

def _build_subscription_from_base(base: str, sub_token: str) -> str:
    base_clean = (base or "").strip().rstrip("/")
    if not base_clean:
        return base_clean

    if "{token}" in base_clean:
        return base_clean.replace("{token}", sub_token)

    parsed = urlparse(base_clean if "://" in base_clean else f"https://{base_clean}")
    path = (parsed.path or "").rstrip("/")

    # Если в base уже задан конкретный /sub/<token>, не добавляем второй токен.
    if "/sub/" in path:
        tail = path.split("/sub/", 1)[1]
        if tail:
            return base_clean

    return f"{base_clean}/{sub_token}"

def _should_prefer_public_subscription(link: str, host_url: str, domain: str | None) -> bool:
    parsed = urlparse(link if "://" in link else f"https://{link}")
    host_parsed = urlparse(host_url if "://" in host_url else f"https://{host_url}")

    link_host = (parsed.hostname or "").strip().lower()
    panel_host = (host_parsed.hostname or "").strip().lower()
    cfg_domain = (domain or "").strip().lower()
    path = (parsed.path or "").rstrip("/")

    if not link_host:
        return False

    same_public_host = link_host == panel_host or (cfg_domain and link_host == cfg_domain)
    if not same_public_host:
        return False

    if parsed.port is not None:
        return True
    if parsed.scheme == "http":
        return True
    if path == "/sub" or path.startswith("/sub/"):
        return True

    return False

def _build_host_candidates(host_url: str) -> list[str]:
    raw = (host_url or "").strip()
    if not raw:
        return []

    if "://" not in raw:
        raw = f"https://{raw}"
    raw = raw.rstrip("/")

    parsed = urlparse(raw)
    if not parsed.netloc:
        return [raw]

    origin = urlunparse((parsed.scheme or "https", parsed.netloc, "", "", "", ""))
    path = (parsed.path or "").rstrip("/")

    candidates: list[str] = []
    seen: set[str] = set()

    def add(candidate_path: str) -> None:
        candidate = f"{origin}{candidate_path}" if candidate_path else origin
        candidate = candidate.rstrip("/")
        if candidate and candidate not in seen:
            seen.add(candidate)
            candidates.append(candidate)

    # 1) Сначала пробуем URL из БД как есть.
    add(path)

    # 2) Если в БД ошибочно указан /panel, срезаем его.
    if path.endswith("/panel"):
        add(path[:-len("/panel")])

    # 3) Частый вариант reverse-proxy: панель за /xui.
    if path in ("", "/"):
        add("/xui")
    elif path == "/panel":
        add("/xui")
        add("")
    elif path == "/xui":
        add("")
    elif path.endswith("/xui/panel"):
        add("/xui")
        add("")
    elif not path.startswith("/xui"):
        add("/xui")

    return candidates

def login_to_host(host_url: str, username: str, password: str, inbound_id: int) -> tuple[Api | None, Inbound | None]:
    candidates = _build_host_candidates(host_url)
    if not candidates:
        logger.error("Пустой host_url для подключения к x-ui.")
        return None, None

    last_error: Exception | None = None
    for candidate in candidates:
        try:
            api = Api(host=candidate, username=username, password=password)
            api.login()
            inbounds: List[Inbound] = api.inbound.get_list()
            target_inbound = next((inbound for inbound in inbounds if inbound.id == inbound_id), None)

            if target_inbound is None:
                logger.error(f"Входящий трафик с ID '{inbound_id}' не найден на хосте '{candidate}'")
                return None, None

            if candidate != host_url.rstrip("/"):
                logger.warning(f"Использован fallback URL для x-ui: '{host_url}' -> '{candidate}'")
            return api, target_inbound
        except Exception as e:
            last_error = e
            logger.warning(f"Не удалось подключиться к x-ui через '{candidate}': {e}")

    logger.error(
        f"Не удалось выполнить вход или получить inbound для хоста '{host_url}'. "
        f"Пробованы URL: {', '.join(candidates)}. Ошибка: {last_error}",
        exc_info=True
    )
    return None, None

def get_connection_string(inbound: Inbound, user_uuid: str, host_url: str, remark: str) -> str | None:
    if not inbound:
        return None

    parsed_url = urlparse(host_url if "://" in host_url else f"https://{host_url}")
    hostname = (parsed_url.hostname or "").strip()
    if not hostname:
        return None

    protocol = (getattr(inbound, "protocol", "") or "").strip().lower()
    port = inbound.port

    if protocol == "trojan":
        params: list[str] = [f"type={quote(getattr(inbound.stream_settings, 'network', 'tcp') or 'tcp', safe='')}"]
        if getattr(inbound.stream_settings, "security", "") == "tls":
            params.append("security=tls")
            tls = getattr(inbound.stream_settings, "tls", None)
            sni = getattr(tls, "sni", "") if tls else ""
            fp = ""
            alpn = []
            if tls:
                settings = getattr(tls, "settings", None)
                fp = getattr(settings, "fingerprint", "") if settings else ""
                alpn = getattr(tls, "alpn", []) or []
            if fp:
                params.append(f"fp={quote(str(fp), safe='')}")
            if sni:
                params.append(f"sni={quote(str(sni), safe='')}")
            if alpn:
                params.append(f"alpn={quote(','.join(str(item) for item in alpn), safe=',')}")
        else:
            params.append("security=none")
        return f"trojan://{quote(user_uuid, safe='')}@{hostname}:{port}?{'&'.join(params)}#{quote(remark)}"

    settings = inbound.stream_settings.reality_settings.get("settings")
    if not settings:
        return None

    public_key = settings.get("publicKey")
    fp = settings.get("fingerprint")
    server_names = inbound.stream_settings.reality_settings.get("serverNames")
    short_ids = inbound.stream_settings.reality_settings.get("shortIds")

    if not all([public_key, server_names, short_ids]):
        return None

    short_id = short_ids[0]
    return (
        f"vless://{user_uuid}@{hostname}:{port}"
        f"?type=tcp&security=reality&pbk={public_key}&fp={fp}&sni={server_names[0]}"
        f"&sid={short_id}&spx=%2F&flow=xtls-rprx-vision#{remark}"
    )

def get_subscription_link(user_uuid: str, host_url: str, host_name: str | None = None, sub_token: str | None = None) -> str:
    """Build subscription URL with the following priority:
    1) Host-specific subscription_url (xui_hosts.subscription_url)
    2) Fallback: domain/host_url + default path
    Supports optional token replacement if base contains "{token}".
    """
    def _append_display_name(link: str) -> str:
        # Для максимальной совместимости клиентов возвращаем "чистую" URL без '#alias'.
        return link

    host_base = None
    try:
        if host_name:
            host = get_host(host_name)
            if host:
                host_base = (host.get("subscription_url") or "").strip()
    except Exception:
        host_base = None

    base = (host_base or "").strip()
    domain = (get_setting("domain") or "").strip()
    public_base = _public_subscription_base(host_url, domain)

    if sub_token:
        public_link = f"{public_base}/{sub_token}" if public_base else ""
        if base:
            built = _build_subscription_from_base(base, sub_token)
            built = _normalize_subscription_url(built, host_url, domain)
            if public_link and _should_prefer_public_subscription(built, host_url, domain):
                built = public_link
            return _append_display_name(built)
        fallback_host = _hostname_from_url(host_url)
        generated = public_link or _normalize_subscription_url(f"https://{fallback_host}/sub/{sub_token}", host_url, domain)
        return _append_display_name(generated)

    if base:
        built = _normalize_subscription_url(base, host_url, domain)
        if public_base and _should_prefer_public_subscription(built, host_url, domain):
            built = f"{public_base}/{user_uuid}?format=v2ray"
        return _append_display_name(built)

    generated = (
        f"{public_base}/{user_uuid}?format=v2ray"
        if public_base else
        _normalize_subscription_url(f"https://{_hostname_from_url(host_url)}/sub/{user_uuid}?format=v2ray", host_url, domain)
    )
    return _append_display_name(generated)

def update_or_create_client_on_panel(api: Api, inbound_id: int, email: str, days_to_add: int | None = None, target_expiry_ms: int | None = None) -> tuple[str | None, int | None, str | None]:
    try:
        inbound_to_modify = api.inbound.get_by_id(inbound_id)
        if not inbound_to_modify:
            raise ValueError(f"Could not find inbound with ID {inbound_id}")
        inbound_protocol = (getattr(inbound_to_modify, "protocol", "") or "").strip().lower()

        if inbound_to_modify.settings.clients is None:
            inbound_to_modify.settings.clients = []
            
        client_index = -1
        for i, client in enumerate(inbound_to_modify.settings.clients):
            if client.email == email:
                client_index = i
                break
        
        # Determine new expiry time
        if target_expiry_ms is not None:
            new_expiry_ms = int(target_expiry_ms)
        else:
            if days_to_add is None:
                raise ValueError("Either days_to_add or target_expiry_ms must be provided")
            if client_index != -1:
                existing_client = inbound_to_modify.settings.clients[client_index]
                if existing_client.expiry_time > int(datetime.now().timestamp() * 1000):
                    current_expiry_dt = datetime.fromtimestamp(existing_client.expiry_time / 1000)
                    new_expiry_dt = current_expiry_dt + timedelta(days=days_to_add)
                else:
                    new_expiry_dt = datetime.now() + timedelta(days=days_to_add)
            else:
                new_expiry_dt = datetime.now() + timedelta(days=days_to_add)

            new_expiry_ms = int(new_expiry_dt.timestamp() * 1000)

        client_sub_token: str | None = None

        if client_index != -1:
            # Disable auto-reset/auto-renew on extension
            try:
                inbound_to_modify.settings.clients[client_index].reset = 0
            except Exception:
                pass
            inbound_to_modify.settings.clients[client_index].enable = True
            inbound_to_modify.settings.clients[client_index].expiry_time = new_expiry_ms

            existing_client = inbound_to_modify.settings.clients[client_index]
            if inbound_protocol == "trojan":
                if not getattr(existing_client, "password", ""):
                    existing_client.password = _protocol_client_secret(inbound_protocol)
                try:
                    existing_client.id = ""
                except Exception:
                    pass
                try:
                    existing_client.flow = ""
                except Exception:
                    pass
            client_uuid = _client_identifier(existing_client, inbound_protocol)
            try:
                sub_token_existing = None
                for attr in ("subId", "subscription", "sub_id"):
                    if hasattr(existing_client, attr):
                        val = getattr(existing_client, attr)
                        if val:
                            sub_token_existing = val
                            break
                if sub_token_existing:
                    client_sub_token = sub_token_existing
                else:
                    client_sub_token = secrets.token_hex(12)
                    for attr in ("subId", "subscription", "sub_id"):
                        try:
                            setattr(existing_client, attr, client_sub_token)
                        except Exception:
                            pass
            except Exception:
                pass
        else:
            client_uuid = _protocol_client_secret(inbound_protocol)
            client_kwargs = {
                "email": email,
                "enable": True,
                "expiry_time": new_expiry_ms,
            }
            if inbound_protocol == "trojan":
                client_kwargs["password"] = client_uuid
                client_kwargs["id"] = ""
            else:
                client_kwargs["id"] = client_uuid
                if inbound_protocol == "vless":
                    client_kwargs["flow"] = "xtls-rprx-vision"

            new_client = Client(**client_kwargs)
            # Ensure no auto-reset/auto-renew for new clients
            try:
                setattr(new_client, "reset", 0)
            except Exception:
                pass

            try:
                client_sub_token = secrets.token_hex(12)
                for attr in ("subId", "subscription", "sub_id"):
                    try:
                        setattr(new_client, attr, client_sub_token)
                    except Exception:
                        pass
            except Exception:
                pass
            inbound_to_modify.settings.clients.append(new_client)

        api.inbound.update(inbound_id, inbound_to_modify)

        return client_uuid, new_expiry_ms, client_sub_token

    except Exception as e:
        logger.error(f"Ошибка в update_or_create_client_on_panel: {e}", exc_info=True)
        return None, None, None

async def create_or_update_key_on_host(host_name: str, email: str, days_to_add: int | None = None, expiry_timestamp_ms: int | None = None) -> Dict | None:
    host_data = get_host(host_name)
    if not host_data:
        logger.error(f"Сбой рабочего процесса: Хост '{host_name}' не найден в базе данных.")
        return None

    api, inbound = login_to_host(
        host_url=host_data['host_url'],
        username=host_data['host_username'],
        password=host_data['host_pass'],
        inbound_id=host_data['host_inbound_id']
    )
    if not api or not inbound:
        logger.error(f"Сбой рабочего процесса: Не удалось войти или найти inbound на хосте '{host_name}'.")
        return None
        
    # Prefer exact expiry when provided (e.g., switching hosts), otherwise add days (purchase/extend/trial)
    client_uuid, new_expiry_ms, client_sub_token = update_or_create_client_on_panel(
        api, inbound.id, email, days_to_add=days_to_add, target_expiry_ms=expiry_timestamp_ms
    )

    if not client_uuid:
        logger.error(f"Сбой рабочего процесса: Не удалось создать/обновить клиента '{email}' на хосте '{host_name}'.")
        return None
    
    display_name = (getattr(inbound, "remark", "") or host_name or "VPN").strip()
    subscription_string = get_subscription_link(client_uuid, host_data['host_url'], host_name, sub_token=client_sub_token)
    connection_string = get_connection_string(inbound, client_uuid, host_data['host_url'], display_name) or subscription_string
    
    logger.info(f"Успешно обработан ключ для '{email}' на хосте '{host_name}'.")
    
    
    return {
        "client_uuid": client_uuid,
        "email": email,
        "expiry_timestamp_ms": new_expiry_ms,
        "connection_string": connection_string,
        "subscription_string": subscription_string,
        "display_name": display_name,
        "host_name": host_name
    }

async def get_key_details_from_host(key_data: dict) -> dict | None:
    host_name = key_data.get('host_name')
    if not host_name:
        logger.error(f"Не удалось получить данные ключа: отсутствует host_name для key_id {key_data.get('key_id')}")
        return None

    host_db_data = get_host(host_name)
    if not host_db_data:
        logger.error(f"Не удалось получить данные ключа: хост '{host_name}' не найден в базе данных.")
        return None

    api, inbound = login_to_host(
        host_url=host_db_data['host_url'],
        username=host_db_data['host_username'],
        password=host_db_data['host_pass'],
        inbound_id=host_db_data['host_inbound_id']
    )
    if not api or not inbound: return None

    inbound_protocol = (getattr(inbound, "protocol", "") or "").strip().lower()
    client_sub_token = None
    resolved_client_id = key_data['xui_client_uuid']
    try:
        if inbound.settings and inbound.settings.clients:
            for client in inbound.settings.clients:
                client_id = _client_identifier(client, inbound_protocol)
                if client_id == key_data['xui_client_uuid'] or getattr(client, "email", None) == key_data.get('email'):
                    if client_id:
                        resolved_client_id = client_id
                    candidate_fields = ("subId", "subscription", "sub_id", "subscriptionId", "subscription_token")
                    for attr in candidate_fields:
                        val = None
                        if hasattr(client, attr):
                            val = getattr(client, attr)
                        else:
                            try:
                                val = client.get(attr)
                            except Exception:
                                pass
                        if val:
                            client_sub_token = val
                            break
                    break
    except Exception:
        pass
    display_name = (getattr(inbound, "remark", "") or host_name or "VPN").strip()
    subscription_string = get_subscription_link(resolved_client_id, host_db_data['host_url'], host_name, sub_token=client_sub_token)
    connection_string = get_connection_string(inbound, resolved_client_id, host_db_data['host_url'], display_name) or subscription_string
    return {
        "connection_string": connection_string,
        "subscription_string": subscription_string,
        "connect_url": build_connect_page_url_for_key(key_data),
        "display_name": display_name,
    }

async def delete_client_on_host(host_name: str, client_email: str) -> bool:
    host_data = get_host(host_name)
    if not host_data:
        logger.error(f"Не удалось удалить клиента: хост '{host_name}' не найден.")
        return False

    api, inbound = login_to_host(
        host_url=host_data['host_url'],
        username=host_data['host_username'],
        password=host_data['host_pass'],
        inbound_id=host_data['host_inbound_id']
    )

    if not api or not inbound:
        logger.error(f"Не удалось удалить клиента: ошибка входа или поиска inbound для хоста '{host_name}'.")
        return False
        
    try:
        client_to_delete = get_key_by_email(client_email)
        if client_to_delete:
            try:
                api.client.delete(inbound.id, client_to_delete['xui_client_uuid'])
            except Exception:
                protocol = (getattr(inbound, "protocol", "") or "").strip().lower()
                fallback_id = None
                if inbound.settings and inbound.settings.clients:
                    for client in inbound.settings.clients:
                        if getattr(client, "email", None) == client_email:
                            fallback_id = _client_identifier(client, protocol)
                            break
                if not fallback_id:
                    raise
                api.client.delete(inbound.id, fallback_id)
            logger.info(f"Клиент '{client_email}' успешно удалён с хоста '{host_name}'.")
            return True
        else:
            logger.warning(f"Клиент с email '{client_email}' не найден на хосте '{host_name}' для удаления (возможно, уже удалён).")
            return True
            
    except Exception as e:
        logger.error(f"Не удалось удалить клиента '{client_email}' с хоста '{host_name}': {e}", exc_info=True)
        return False
