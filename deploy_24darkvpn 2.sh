#!/usr/bin/env bash
set -euo pipefail

# ====== Deploy settings ======
SSH_HOST="${SSH_HOST:-147.45.169.41}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
SSH_PASSWORD="${SSH_PASSWORD:-}"

DOMAIN="${DOMAIN:-24darkvpn.ru}"
LE_EMAIL="${LE_EMAIL:-admin@24darkvpn.ru}"
REMOTE_DIR="${REMOTE_DIR:-/opt/24darkvpn-bot}"
BOT_UPSTREAM="${BOT_UPSTREAM:-http://127.0.0.1:1488}"
XUI_UPSTREAM="${XUI_UPSTREAM:-http://127.0.0.1:2053}"

XUI_UPSTREAM="${XUI_UPSTREAM%/}"
BOT_UPSTREAM="${BOT_UPSTREAM%/}"

if command -v sshpass >/dev/null 2>&1; then
  if [[ -z "$SSH_PASSWORD" ]]; then
    read -rsp "Введите SSH пароль для ${SSH_USER}@${SSH_HOST}: " SSH_PASSWORD
    echo
  fi
  SSH_BASE=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}")
else
  echo "⚠️ sshpass не найден. Продолжаю через обычный ssh (пароль нужно будет ввести вручную)."
  SSH_BASE=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}")
fi

echo "1/4 Копирую проект на сервер: ${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}"
tar \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='users.db' \
  -czf - . | "${SSH_BASE[@]}" "mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR'"

echo "2/4 Устанавливаю зависимости на сервере и запускаю контейнер"
"${SSH_BASE[@]}" "export REMOTE_DIR='$REMOTE_DIR'; bash -s" <<'REMOTE_BOOTSTRAP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y docker.io nginx certbot

if ! apt-get install -y docker-compose-plugin; then
  echo "⚠️ Пакет docker-compose-plugin недоступен, пробую установить docker-compose..."
  apt-get install -y docker-compose
fi

systemctl enable --now docker
systemctl enable --now nginx

cd "$REMOTE_DIR"
if docker compose version >/dev/null 2>&1; then
  docker compose up -d --build
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d --build
else
  echo "❌ Не найден ни 'docker compose', ни 'docker-compose'." >&2
  exit 1
fi
REMOTE_BOOTSTRAP

echo "3/4 Настраиваю Nginx и SSL для ${DOMAIN}"
"${SSH_BASE[@]}" \
  "export DOMAIN='$DOMAIN' LE_EMAIL='$LE_EMAIL' BOT_UPSTREAM='$BOT_UPSTREAM' XUI_UPSTREAM='$XUI_UPSTREAM'; bash -s" <<'REMOTE_NGINX'
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

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
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

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
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
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /xui;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_redirect ~^(/.*)\$ /xui\$1;

        # Попытка сохранить корректные пути статических файлов при прокси через /xui/
        sub_filter_once off;
        sub_filter_types text/html text/css application/javascript;
        sub_filter 'href="/' 'href="/xui/';
        sub_filter 'src="/' 'src="/xui/';
        sub_filter 'action="/' 'action="/xui/';
    }
}
EOF

nginx -t
systemctl reload nginx
REMOTE_NGINX

echo "4/4 Готово"
echo "Бот-панель: https://${DOMAIN}"
echo "XUI-панель: https://${DOMAIN}/xui"
echo "Если XUI у вас слушает не 127.0.0.1:2053, перезапустите скрипт с XUI_UPSTREAM:"
echo "  XUI_UPSTREAM=http://127.0.0.1:ВАШ_ПОРТ ./deploy_24darkvpn.sh"
