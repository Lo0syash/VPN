#!/usr/bin/env bash
set -euo pipefail

# ====== Deploy settings ======
SSH_HOST="${SSH_HOST:-64.188.117.188}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_INSECURE="${SSH_INSECURE:-0}" # 1 -> отключить strict host key check

DOMAIN="${DOMAIN:-24darkvpn.ru}"
LE_EMAIL="${LE_EMAIL:-admin@24darkvpn.ru}"
REMOTE_DIR="${REMOTE_DIR:-/opt/24darkvpn-bot}"
REMOTE_DB_BACKUP="${REMOTE_DB_BACKUP:-/root/24darkvpn-users.db.bak}"
CLEAR_REMOTE_DB="${CLEAR_REMOTE_DB:-0}"
BOT_UPSTREAM="${BOT_UPSTREAM:-http://127.0.0.1:1488}"
XUI_UPSTREAM="${XUI_UPSTREAM:-http://127.0.0.1:2053}"
SUB_UPSTREAM="${SUB_UPSTREAM:-http://127.0.0.1:2096}"
SUB_PROFILE_TITLE="${SUB_PROFILE_TITLE:-🇳🇱 Нидерланды}"
XUI_API_URL="${XUI_API_URL:-$XUI_UPSTREAM}"
XUI_HOST_NAME="${XUI_HOST_NAME:-VPN}"
XUI_USERNAME="${XUI_USERNAME:-admin}"
XUI_PASSWORD="${XUI_PASSWORD:-}"
XUI_INBOUND_REMARK="${XUI_INBOUND_REMARK:-🇳🇱 Нидерланды}"
XUI_INBOUND_PORT="${XUI_INBOUND_PORT:-43437}"
XUI_TLS_SERVER_NAME="${XUI_TLS_SERVER_NAME:-$DOMAIN}"
XUI_TLS_FINGERPRINT="${XUI_TLS_FINGERPRINT:-chrome}"
XUI_TLS_ALPN="${XUI_TLS_ALPN:-h2,http/1.1}"
PYTHON_VERSION="${PYTHON_VERSION:-3.13.2}"

BOT_UPSTREAM="${BOT_UPSTREAM%/}"
XUI_UPSTREAM="${XUI_UPSTREAM%/}"
SUB_UPSTREAM="${SUB_UPSTREAM%/}"
XUI_API_URL="${XUI_API_URL%/}"

SSH_OPTS=(-p "$SSH_PORT")
if [[ "$SSH_INSECURE" == "1" ]]; then
  SSH_OPTS+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
else
  SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
fi

if command -v sshpass >/dev/null 2>&1; then
  if [[ -z "$SSH_PASSWORD" ]]; then
    read -rsp "Введите SSH пароль для ${SSH_USER}@${SSH_HOST}: " SSH_PASSWORD
    echo
  fi
  SSH_BASE=(sshpass -p "$SSH_PASSWORD" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}")
else
  echo "sshpass не найден -> будет обычный ssh с ручным вводом пароля."
  SSH_BASE=(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}")
fi

if [[ -z "$XUI_PASSWORD" ]]; then
  read -rsp "Введите пароль панели x-ui для ${XUI_USERNAME}: " XUI_PASSWORD
  echo
fi

XUI_PASSWORD_B64="$(printf '%s' "$XUI_PASSWORD" | base64)"

echo "1/6 Очищаю старый деплой на сервере (без Docker)"
"${SSH_BASE[@]}" "export REMOTE_DIR='$REMOTE_DIR' REMOTE_DB_BACKUP='$REMOTE_DB_BACKUP' CLEAR_REMOTE_DB='$CLEAR_REMOTE_DB'; bash -s" <<'REMOTE_CLEAN'
set -euo pipefail

systemctl stop 24darkvpn-bot 2>/dev/null || true
systemctl disable 24darkvpn-bot 2>/dev/null || true
rm -f /etc/systemd/system/24darkvpn-bot.service
systemctl daemon-reload

# Сохраняем базу бота между деплоями, только если не запрошен полный сброс.
if [[ "$CLEAR_REMOTE_DB" != "1" && -f "$REMOTE_DIR/users.db" ]]; then
  cp -f "$REMOTE_DIR/users.db" "$REMOTE_DB_BACKUP"
else
  rm -f "$REMOTE_DB_BACKUP" "$REMOTE_DIR/users.db"
fi

# Удаляем предыдущий проект
rm -rf "$REMOTE_DIR"
mkdir -p "$REMOTE_DIR"

# Удаляем старый dockerized деплой и Docker пакеты
if command -v docker >/dev/null 2>&1; then
  docker rm -f 3xui-shopbot 2>/dev/null || true
  docker ps -aq --filter "name=3xui-shopbot" | xargs -r docker rm -f || true
fi

apt-get purge -y docker.io docker-ce docker-ce-cli containerd containerd.io docker-compose docker-compose-plugin 2>/dev/null || true
apt-get autoremove -y --purge || true
rm -rf /var/lib/docker /etc/docker 2>/dev/null || true
REMOTE_CLEAN

echo "2/6 Копирую проект на сервер: ${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}"
tar \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='users.db' \
  -czf - . | "${SSH_BASE[@]}" "mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR'"

echo "3/6 Ставлю Python 3.13 и зависимости, запускаю бот через systemd"
"${SSH_BASE[@]}" \
  "export REMOTE_DIR='$REMOTE_DIR' REMOTE_DB_BACKUP='$REMOTE_DB_BACKUP' CLEAR_REMOTE_DB='$CLEAR_REMOTE_DB' PYTHON_VERSION='$PYTHON_VERSION'; bash -s" <<'REMOTE_BOOTSTRAP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y \
  curl ca-certificates nginx certbot python3-certbot-nginx sqlite3 \
  build-essential make gcc \
  zlib1g-dev libssl-dev libbz2-dev libreadline-dev \
  libsqlite3-dev libffi-dev liblzma-dev tk-dev uuid-dev xz-utils

# Python 3.13: сначала пробуем apt, если не найдено — собираем из исходников
if ! command -v python3.13 >/dev/null 2>&1; then
  apt-get install -y python3.13 python3.13-venv python3.13-dev || true
fi

if ! command -v python3.13 >/dev/null 2>&1; then
  cd /tmp
  curl -fsSLO "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
  tar -xzf "Python-${PYTHON_VERSION}.tgz"
  cd "Python-${PYTHON_VERSION}"
  ./configure --prefix=/usr/local --enable-shared
  make -j"$(nproc)"
  make altinstall
  echo "/usr/local/lib" > /etc/ld.so.conf.d/python313.conf
  ldconfig
fi

if ! command -v python3.13 >/dev/null 2>&1; then
  echo "Не удалось установить python3.13" >&2
  exit 1
fi

# Код ожидает /app/project/users.db -> делаем совместимый symlink
mkdir -p /app
ln -sfn "$REMOTE_DIR" /app/project

if [[ "$CLEAR_REMOTE_DB" != "1" && -f "$REMOTE_DB_BACKUP" && ! -f "$REMOTE_DIR/users.db" ]]; then
  mv -f "$REMOTE_DB_BACKUP" "$REMOTE_DIR/users.db"
fi

cd "$REMOTE_DIR"
python3.13 -m venv .venv
./.venv/bin/pip install --upgrade pip setuptools wheel
./.venv/bin/pip install -e .

# Явно инициализируем БД, чтобы таблицы и настройки были готовы к автоконфигу.
./.venv/bin/python - <<'PY'
from shop_bot.data_manager.database import initialize_db
initialize_db()
PY

cat > /etc/systemd/system/24darkvpn-bot.service <<EOF
[Unit]
Description=24DarkVPN Bot (no Docker)
After=network.target

[Service]
Type=simple
WorkingDirectory=${REMOTE_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${REMOTE_DIR}/.venv/bin/python -m shop_bot
Restart=always
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now 24darkvpn-bot

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi
REMOTE_BOOTSTRAP

echo "4/6 Настраиваю Nginx и SSL"
"${SSH_BASE[@]}" \
  "export DOMAIN='$DOMAIN' LE_EMAIL='$LE_EMAIL' BOT_UPSTREAM='$BOT_UPSTREAM' XUI_UPSTREAM='$XUI_UPSTREAM' SUB_UPSTREAM='$SUB_UPSTREAM' SUB_PROFILE_TITLE='$SUB_PROFILE_TITLE'; bash -s" <<'REMOTE_NGINX'
set -euo pipefail

CONF_FILE="/etc/nginx/sites-available/${DOMAIN}.conf"
WEBROOT="/var/www/certbot"
mkdir -p "$WEBROOT"

cat > "$CONF_FILE" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        alias ${WEBROOT}/.well-known/acme-challenge/;
        default_type text/plain;
        try_files \$uri =404;
        add_header Cache-Control "no-cache";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

mkdir -p "${WEBROOT}/.well-known/acme-challenge"
ACME_TEST_FILE="${WEBROOT}/.well-known/acme-challenge/nginx-self-test"
echo "ok-$(date +%s)" > "$ACME_TEST_FILE"
if ! curl -fsS "http://${DOMAIN}/.well-known/acme-challenge/nginx-self-test" >/dev/null; then
  echo "Ошибка: Nginx не отдает ACME challenge по HTTP, certbot завершен." >&2
  echo "Проверьте A/AAAA DNS записи ${DOMAIN} и что порт 80 доступен извне." >&2
  exit 1
fi
rm -f "$ACME_TEST_FILE"

if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  certbot certonly --webroot \
    -w "${WEBROOT}" \
    -d "${DOMAIN}" \
    --email "${LE_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive
fi

cat > "$CONF_FILE" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        alias ${WEBROOT}/.well-known/acme-challenge/;
        default_type text/plain;
        try_files \$uri =404;
        add_header Cache-Control "no-cache";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location ^~ /.well-known/acme-challenge/ {
        alias ${WEBROOT}/.well-known/acme-challenge/;
        default_type text/plain;
        try_files \$uri =404;
        add_header Cache-Control "no-cache";
    }

    # Защита от абсолютных редиректов/ссылок x-ui на /panel/*
    location = /panel {
        return 301 /xui/panel/;
    }

    location ^~ /panel/ {
        return 301 /xui\$uri\$is_args\$args;
    }

    # HTTPS-подписки для клиентов: https://DOMAIN/sub/{token}
    location ^~ /sub/ {
        proxy_pass ${SUB_UPSTREAM}/sub/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        add_header Profile-Title "${SUB_PROFILE_TITLE}" always;
        add_header Profile-Web-Page-Url "https://${DOMAIN}" always;
        add_header Profile-Update-Interval "1" always;
    }

    location ^~ /json/ {
        proxy_pass ${SUB_UPSTREAM}/json/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass ${BOT_UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location = /xui {
        return 301 /xui/;
    }

    location /xui/ {
        proxy_pass ${XUI_UPSTREAM}/;
        proxy_http_version 1.1;
        # sub_filter не работает по сжатому ответу, отключаем gzip со стороны upstream
        proxy_set_header Accept-Encoding "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /xui;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_redirect ~^(/.*)\$ /xui\$1;
        sub_filter_once off;
        sub_filter_types text/html text/css application/javascript;
        sub_filter 'href="/' 'href="/xui/';
        sub_filter 'src="/' 'src="/xui/';
        sub_filter 'action="/' 'action="/xui/';
        sub_filter "const basePath = '\\/';" "const basePath = '\\/xui\\/';";
        sub_filter "url('/" "url('/xui/";
        sub_filter 'url("/' 'url("/xui/';
    }
}
EOF

nginx -t
systemctl reload nginx
REMOTE_NGINX

echo "5/6 Автонастраиваю x-ui inbound и ссылку подписки"
"${SSH_BASE[@]}" \
  "export REMOTE_DIR='$REMOTE_DIR' DOMAIN='$DOMAIN' XUI_API_URL='$XUI_API_URL' XUI_HOST_NAME='$XUI_HOST_NAME' XUI_USERNAME='$XUI_USERNAME' XUI_PASSWORD_B64='$XUI_PASSWORD_B64' XUI_INBOUND_REMARK='$XUI_INBOUND_REMARK' XUI_INBOUND_PORT='$XUI_INBOUND_PORT' XUI_TLS_SERVER_NAME='$XUI_TLS_SERVER_NAME' XUI_TLS_FINGERPRINT='$XUI_TLS_FINGERPRINT' XUI_TLS_ALPN='$XUI_TLS_ALPN' SUB_PROFILE_TITLE='$SUB_PROFILE_TITLE'; bash -s" <<'REMOTE_XUI'
set -euo pipefail

cd "$REMOTE_DIR"

./.venv/bin/python - <<'PY'
import json
import os
import sqlite3
import base64
import socket
import subprocess

import requests

domain = os.environ["DOMAIN"].strip()
remote_dir = os.environ["REMOTE_DIR"].strip()
xui_api_url = os.environ["XUI_API_URL"].strip().rstrip("/")
xui_host_name = os.environ["XUI_HOST_NAME"].strip() or "VPN"
xui_username = os.environ["XUI_USERNAME"].strip() or "admin"
xui_password = base64.b64decode(os.environ["XUI_PASSWORD_B64"]).decode()
xui_inbound_remark = os.environ["XUI_INBOUND_REMARK"].strip() or "24darkvpn-trojan"
xui_inbound_port = int(os.environ["XUI_INBOUND_PORT"])
xui_tls_server_name = os.environ["XUI_TLS_SERVER_NAME"].strip() or domain
xui_tls_fingerprint = os.environ["XUI_TLS_FINGERPRINT"].strip() or "chrome"
xui_tls_alpn = [item.strip() for item in os.environ["XUI_TLS_ALPN"].split(",") if item.strip()]
sub_profile_title = os.environ["SUB_PROFILE_TITLE"].strip() or "24DarkVPN"

if not xui_password:
    raise SystemExit("XUI_PASSWORD пустой. Укажите пароль панели x-ui.")
if not xui_tls_alpn:
    xui_tls_alpn = ["h2", "http/1.1"]

public_panel_url = f"https://{domain}/xui"
public_subscription_url = f"https://{domain}/sub/{{token}}"
db_path = os.path.join(remote_dir, "users.db")
tls_cert_path = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
tls_key_path = f"/etc/letsencrypt/live/{domain}/privkey.pem"

if not os.path.exists(tls_cert_path) or not os.path.exists(tls_key_path):
    raise SystemExit("TLS-сертификаты не найдены. Ожидались Let's Encrypt файлы fullchain.pem и privkey.pem.")

session = requests.Session()
session.headers.update({"X-Requested-With": "XMLHttpRequest"})

login_resp = session.post(
    f"{xui_api_url}/login",
    data={"username": xui_username, "password": xui_password},
    timeout=20,
)
login_resp.raise_for_status()
login_json = login_resp.json()
if not login_json.get("success"):
    raise SystemExit(f"Не удалось войти в x-ui API: {login_json}")

settings_resp = session.post(f"{xui_api_url}/panel/setting/all", timeout=20)
settings_resp.raise_for_status()
settings_json = settings_resp.json()
if not settings_json.get("success"):
    raise SystemExit(f"Не удалось получить настройки x-ui: {settings_json}")

all_settings = settings_json.get("obj") or {}
all_settings.update(
    {
        "subEnable": True,
        "subJsonEnable": True,
        "subTitle": sub_profile_title,
        "subSupportUrl": f"https://{domain}",
        "subProfileUrl": f"https://{domain}",
        "subUpdates": 1,
        "subShowInfo": False,
        "remarkModel": "-i",
        "subURI": f"https://{domain}/sub/",
        "subJsonURI": f"https://{domain}/json/",
    }
)

settings_update_resp = session.post(
    f"{xui_api_url}/panel/setting/update",
    data=all_settings,
    timeout=20,
)
settings_update_resp.raise_for_status()
settings_update_json = settings_update_resp.json()
if not settings_update_json.get("success"):
    raise SystemExit(f"Не удалось обновить настройки x-ui для подписок: {settings_update_json}")

list_resp = session.get(f"{xui_api_url}/panel/api/inbounds/list", timeout=20)
list_resp.raise_for_status()
list_json = list_resp.json()
if not list_json.get("success"):
    raise SystemExit(f"Не удалось получить список inbound: {list_json}")

inbounds = list_json.get("obj") or []
managed_inbound = None

def _parse_json(value, fallback):
    if isinstance(value, dict):
        return value
    if not value:
        return fallback
    try:
        return json.loads(value)
    except Exception:
        return fallback

def _inbound_port(inbound):
    try:
        return int(inbound.get("port") or 0)
    except Exception:
        return 0

def _inbound_id(inbound):
    try:
        return int(inbound.get("id") or 0)
    except Exception:
        return 0

def _is_trojan(inbound):
    return (inbound.get("protocol") or "").strip().lower() == "trojan"

def _port_is_free(candidate_port, skip_port=None):
    if skip_port and candidate_port == skip_port:
        return True
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", candidate_port))
            return True
        except OSError:
            return False

def _pick_port(preferred_port):
    for offset in range(0, 100):
        candidate = preferred_port + offset
        collision = next((item for item in inbounds if _inbound_port(item) == candidate), None)
        if collision is not None:
            continue
        if _port_is_free(candidate):
            return candidate
    raise SystemExit("Не удалось подобрать свободный порт для Trojan inbound в диапазоне preferred+100.")

def _build_inbound_payload(port, clients=None, fallbacks=None):
    return {
        "remark": xui_inbound_remark,
        "enable": True,
        "listen": "",
        "port": port,
        "protocol": "trojan",
        "expiryTime": 0,
        "settings": json.dumps(
            {
                "clients": clients or [],
                "fallbacks": fallbacks or [],
            },
            separators=(",", ":"),
        ),
        "streamSettings": json.dumps(
            {
                "network": "tcp",
                "security": "tls",
                "externalProxy": [],
                "tlsSettings": {
                    "serverName": xui_tls_server_name,
                    "minVersion": "1.2",
                    "maxVersion": "1.3",
                    "cipherSuites": "",
                    "rejectUnknownSni": False,
                    "disableSystemRoot": False,
                    "enableSessionResumption": False,
                    "certificates": [
                        {
                            "certificateFile": tls_cert_path,
                            "keyFile": tls_key_path,
                            "oneTimeLoading": False,
                            "usage": "encipherment",
                            "buildChain": False,
                        }
                    ],
                    "alpn": xui_tls_alpn,
                    "echServerKeys": "",
                    "echForceQuery": "none",
                    "settings": {
                        "fingerprint": xui_tls_fingerprint,
                        "echConfigList": "",
                    },
                },
                "tcpSettings": {
                    "acceptProxyProtocol": False,
                    "header": {"type": "none"},
                },
            },
            separators=(",", ":"),
        ),
        "sniffing": json.dumps(
            {
                "enabled": True,
                "destOverride": ["http", "tls", "quic", "fakedns"],
                "metadataOnly": False,
                "routeOnly": False,
            },
            separators=(",", ":"),
        ),
    }

for inbound in inbounds:
    if _is_trojan(inbound) and (inbound.get("remark") or "").strip() == xui_inbound_remark:
        managed_inbound = inbound
        break
if managed_inbound is None:
    for inbound in inbounds:
        if _is_trojan(inbound) and _inbound_port(inbound) == xui_inbound_port:
            managed_inbound = inbound
            break

restart_required = False
created = False
updated = False

if managed_inbound is None:
    selected_port = _pick_port(xui_inbound_port)
    inbound_payload = _build_inbound_payload(selected_port)

    add_resp = session.post(f"{xui_api_url}/panel/api/inbounds/add", data=inbound_payload, timeout=20)
    add_resp.raise_for_status()
    add_json = add_resp.json()
    if not add_json.get("success"):
        raise SystemExit(f"Не удалось создать inbound в x-ui: {add_json}")

    inbound_obj = add_json.get("obj") or {}
    inbound_id = int(inbound_obj.get("id") or 0)
    if inbound_id == 0:
        refresh_resp = session.get(f"{xui_api_url}/panel/api/inbounds/list", timeout=20)
        refresh_resp.raise_for_status()
        refresh_json = refresh_resp.json()
        if not refresh_json.get("success"):
            raise SystemExit(f"Не удалось повторно получить inbound после создания: {refresh_json}")
        for inbound in refresh_json.get("obj") or []:
            if _is_trojan(inbound) and (inbound.get("remark") or "").strip() == xui_inbound_remark:
                inbound_id = int(inbound.get("id") or 0)
                managed_inbound = inbound
                break
    if inbound_id == 0:
        raise SystemExit("Inbound создан, но не удалось определить его ID.")
    restart_required = True
    created = True
else:
    inbound_id = int(managed_inbound.get("id") or 0)
    if inbound_id == 0:
        raise SystemExit("У найденного inbound отсутствует ID.")
    selected_port = _inbound_port(managed_inbound) or xui_inbound_port

    current_stream = _parse_json(managed_inbound.get("streamSettings"), {})
    current_settings = _parse_json(managed_inbound.get("settings"), {})
    current_security = (current_stream.get("security") or "").strip().lower()
    current_protocol = (managed_inbound.get("protocol") or "").strip().lower()
    current_remark = (managed_inbound.get("remark") or "").strip()
    current_tls = current_stream.get("tlsSettings") or {}
    current_certificates = current_tls.get("certificates") or []

    needs_update = any(
        [
            current_protocol != "trojan",
            current_security != "tls",
            current_remark != xui_inbound_remark,
            not current_certificates,
            current_tls.get("serverName") != xui_tls_server_name,
        ]
    )

    if needs_update:
        update_payload = _build_inbound_payload(
            selected_port,
            clients=current_settings.get("clients") or [],
            fallbacks=current_settings.get("fallbacks") or [],
        )
        update_resp = session.post(
            f"{xui_api_url}/panel/api/inbounds/update/{inbound_id}",
            data=update_payload,
            timeout=20,
        )
        update_resp.raise_for_status()
        update_json = update_resp.json()
        if not update_json.get("success"):
            raise SystemExit(f"Не удалось обновить Trojan inbound в x-ui: {update_json}")
        restart_required = True
        updated = True

subprocess.run(
    f"if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then ufw allow {selected_port}/tcp || true; fi",
    shell=True,
    executable='/bin/bash',
    check=False,
)

if restart_required:
    restart_resp = session.post(f"{xui_api_url}/panel/api/server/restartXrayService", timeout=30)
    restart_resp.raise_for_status()
    restart_json = restart_resp.json()
    if not restart_json.get("success"):
        raise SystemExit(f"Не удалось перезапустить Xray после изменения inbound: {restart_json}")

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    cur.execute(
        "INSERT OR REPLACE INTO bot_settings (key, value) VALUES (?, ?)",
        ("domain", domain),
    )

    cur.execute(
        "SELECT 1 FROM xui_hosts WHERE TRIM(host_name) = TRIM(?)",
        (xui_host_name,),
    )
    exists = cur.fetchone() is not None

    if exists:
        cur.execute(
            """
            UPDATE xui_hosts
            SET host_url = ?, host_username = ?, host_pass = ?, host_inbound_id = ?, subscription_url = ?
            WHERE TRIM(host_name) = TRIM(?)
            """,
            (
                public_panel_url,
                xui_username,
                xui_password,
                inbound_id,
                public_subscription_url,
                xui_host_name,
            ),
        )
    else:
        cur.execute(
            """
            INSERT INTO xui_hosts (host_name, host_url, host_username, host_pass, host_inbound_id, subscription_url)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                xui_host_name,
                public_panel_url,
                xui_username,
                xui_password,
                inbound_id,
                public_subscription_url,
            ),
        )
    conn.commit()
finally:
    conn.close()

print(f"inbound_id={inbound_id}")
print(f"created={str(created).lower()}")
print(f"updated={str(updated).lower()}")
print(f"inbound_protocol=trojan")
print(f"inbound_port={selected_port}")
print(f"panel_url={public_panel_url}")
print(f"subscription_url={public_subscription_url}")
PY

systemctl restart 24darkvpn-bot
REMOTE_XUI

echo "6/6 Готово"
echo "Бот-панель: https://${DOMAIN}"
echo "XUI-панель: https://${DOMAIN}/xui"
echo "Trojan inbound: ${XUI_INBOUND_REMARK} (порт по умолчанию ${XUI_INBOUND_PORT}, при конфликте будет выбран свободный)"
echo "Подписка: https://${DOMAIN}/sub/{token}"
echo "Проверка сервиса: systemctl status 24darkvpn-bot --no-pager"
echo "Логи: journalctl -u 24darkvpn-bot -f"
