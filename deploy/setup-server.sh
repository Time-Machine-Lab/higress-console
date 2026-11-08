#!/usr/bin/env bash
# One-time, idempotent server preparation. Run as root on the Higress host:
#   DOMAIN=mcp.tmlab.top bash setup-server.sh
#
# - pins the currently running all-in-one image as higress-aio-base:pinned
# - generates the console API token (plaintext kept in /opt/higress/secrets, only its sha256 goes to the container)
# - installs nginx + certbot, issues the certificate and enables automatic renewal
set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN, e.g. DOMAIN=mcp.tmlab.top}"
ROOT=/opt/higress
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
umask 077
mkdir -p "$ROOT/secrets" "$ROOT/releases"

# 1. Pin the base image so upstream "latest" changes never sneak in.
if ! docker image inspect higress-aio-base:pinned >/dev/null 2>&1; then
  current="$(docker inspect higress-ai --format '{{.Image}}' 2>/dev/null \
    || docker image inspect higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/all-in-one:latest --format '{{.Id}}')"
  docker tag "$current" higress-aio-base:pinned
  echo "pinned base image $current"
fi

# 2. Console API token.
TOKEN_FILE="$ROOT/secrets/console-api-token"
[ -s "$TOKEN_FILE" ] || openssl rand -hex 32 > "$TOKEN_FILE"
digest="$(tr -d '\n' < "$TOKEN_FILE" | sha256sum | cut -d' ' -f1)"
printf 'HIGRESS_CONSOLE_ADMIN_API_TOKENS=sha256:%s\n' "$digest" > "$ROOT/console.env"
chmod 600 "$ROOT/console.env" "$TOKEN_FILE"

# 3. Redis password used by Higress MCP (created earlier; generate if absent).
[ -s "$ROOT/redis.pass" ] || openssl rand -hex 16 > "$ROOT/redis.pass"

# 4. nginx + certbot.
umask 022
if ! command -v nginx >/dev/null || ! command -v certbot >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot >/dev/null
fi
mkdir -p /var/www/certbot
rm -f /etc/nginx/sites-enabled/default
CONF=/etc/nginx/sites-available/higress-gateway.conf
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  # Serve only the ACME challenge until the certificate exists.
  cat > "$CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
EOF
  ln -sf "$CONF" /etc/nginx/sites-enabled/higress-gateway.conf
  nginx -t && systemctl reload nginx
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email
fi
sed "s/__DOMAIN__/$DOMAIN/g" "$SRC_DIR/nginx/higress-gateway.conf" > "$CONF"
ln -sf "$CONF" /etc/nginx/sites-enabled/higress-gateway.conf
nginx -t && systemctl reload nginx

# Reload nginx after every successful renewal so the new certificate is served.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

echo "setup complete for $DOMAIN"
