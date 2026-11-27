#!/usr/bin/env bash
# Daily: renew the Let's Encrypt certificate (only acts within 30 days of expiry) and reload nginx
# when it changed. If the site is still on the self-signed fallback, try to get a real certificate.
set -euo pipefail
set -a; source /etc/suki.env; set +a
cd "$SUKI_HOME"
mkdir -p /var/log/suki
LOG=/var/log/suki/cert-renew.log
log() { echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"cert_renew\",$1}" | tee -a "$LOG"; }
COMPOSE=(docker compose --project-directory app -f app/docker-compose.yml)
CERTBOT=(docker run --rm -v /etc/letsencrypt:/etc/letsencrypt -v /var/www/certbot:/var/www/certbot docker.io/certbot/certbot:latest)
LE_LIVE=/etc/letsencrypt/live/suki; TLS_DIR=/etc/suki-tls

URL="$(aws ssm get-parameter --name "$PARAM_PREFIX/PUBLIC_URL" --query Parameter.Value --output text)"
HOST="${URL#https://}"; HOST="${HOST%%/*}"
bash ops/tls/duckdns-update.sh "$HOST" >>"$LOG" 2>&1 || log "\"warning\":\"duckdns_update_failed\""

if [[ -s "$LE_LIVE/fullchain.pem" ]]; then
  "${CERTBOT[@]}" renew --webroot -w /var/www/certbot --non-interactive >>"$LOG" 2>&1
else
  "${CERTBOT[@]}" certonly --webroot -w /var/www/certbot --non-interactive --agree-tos \
    --register-unsafely-without-email --cert-name suki -d "$HOST" >>"$LOG" 2>&1
fi

if ! cmp -s "$LE_LIVE/fullchain.pem" "$TLS_DIR/fullchain.pem"; then
  install -m 0644 "$LE_LIVE/fullchain.pem" "$TLS_DIR/fullchain.pem"
  install -m 0600 "$LE_LIVE/privkey.pem" "$TLS_DIR/privkey.pem"
  "${COMPOSE[@]}" exec -T nginx nginx -s reload
  log "\"result\":\"installed_new_certificate\""
else
  log "\"result\":\"ok_no_change\""
fi
