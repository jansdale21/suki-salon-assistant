#!/usr/bin/env bash
# Deploy (or redeploy) Suki on the EC2 instance. Idempotent.
#   sudo /opt/suki/infra/scripts/deploy.sh          # deploy what is checked out
#   sudo /opt/suki/infra/scripts/deploy.sh --pull   # git pull first (used by GitHub Actions via SSM)
set -euo pipefail
set -a; source /etc/suki.env; set +a   # export AWS_REGION etc. to the aws CLI
cd "$SUKI_HOME"
mkdir -p /var/log/suki
LOG=/var/log/suki/deploy.log
log() { echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"deploy\",$1}" | tee -a "$LOG"; }
trap 'log "\"result\":\"failed\",\"line\":$LINENO"' ERR

if [[ "${1:-}" == "--pull" ]]; then
  git fetch --quiet origin
  git reset --hard "origin/$(git rev-parse --abbrev-ref HEAD)"
fi
APP_VERSION="$(git rev-parse --short HEAD)"
log "\"result\":\"started\",\"app_version\":\"$APP_VERSION\""

param() { aws ssm get-parameter --name "$PARAM_PREFIX/$1" --with-decryption --query Parameter.Value --output text; }
param_or() { aws ssm get-parameter --name "$PARAM_PREFIX/$1" --query Parameter.Value --output text 2>/dev/null || echo "$2"; }

# --- pick a LibreChat image that can be pulled (pinned first, then fallbacks)
LIBRECHAT_IMAGE=""
for img in "$(param_or LIBRECHAT_IMAGE registry.librechat.ai/librechat-ai/librechat:v0.8.9)" \
           ghcr.io/danny-avila/librechat:v0.8.9 \
           registry.librechat.ai/librechat-ai/librechat-dev:latest; do
  if docker pull -q "$img" >/dev/null 2>&1; then LIBRECHAT_IMAGE="$img"; break; fi
done
[[ -n "$LIBRECHAT_IMAGE" ]] || { log "\"result\":\"failed\",\"reason\":\"no librechat image\""; exit 1; }

PUBLIC_URL="$(param PUBLIC_URL)"
WEBSITE_URL="$(param_or WEBSITE_URL https://github.com)"

# --- render app/.env from Parameter Store (root-only, git-ignored, never committed)
umask 077
cat > app/.env.tmp <<EOF
AWS_REGION=$AWS_REGION
PARAM_PREFIX=$PARAM_PREFIX
KNOWLEDGE_SOURCE=s3://$CONTENT_BUCKET/content/
APP_VERSION=$APP_VERSION
LIBRECHAT_IMAGE=$LIBRECHAT_IMAGE
MONGO_USER=$(param MONGO_USER)
MONGO_PASSWORD=$(param MONGO_PASSWORD)
DOMAIN_CLIENT=$PUBLIC_URL
DOMAIN_SERVER=$PUBLIC_URL
CREDS_KEY=$(param CREDS_KEY)
CREDS_IV=$(param CREDS_IV)
JWT_SECRET=$(param JWT_SECRET)
JWT_REFRESH_SECRET=$(param JWT_REFRESH_SECRET)
SUKI_GATEWAY_KEY=$(param GATEWAY_TOKEN)
APP_TITLE="Suki · Suklay & Kulay"
CUSTOM_FOOTER="Suki is an information assistant for a fictional salon (SAM10 student project). Answers may be wrong - confirm with the front desk."
HELP_AND_FAQ_URL=$WEBSITE_URL
ALLOW_REGISTRATION=false
ALLOW_EMAIL_LOGIN=true
ALLOW_SOCIAL_LOGIN=false
ALLOW_SOCIAL_REGISTRATION=false
ALLOW_PASSWORD_RESET=false
SEARCH=false
NO_INDEX=true
TRUST_PROXY=2
ENDPOINTS=custom
CONSOLE_JSON=true
DEBUG_LOGGING=false
LIMIT_MESSAGE_USER=true
MESSAGE_USER_MAX=20
MESSAGE_USER_WINDOW=1
LIMIT_MESSAGE_IP=true
MESSAGE_IP_MAX=40
MESSAGE_IP_WINDOW=1
EOF
mv app/.env.tmp app/.env
umask 022

# --- first boot: seed the S3 knowledge base from the repository if it is empty
if [[ -z "$(aws s3 ls "s3://$CONTENT_BUCKET/content/" 2>/dev/null)" ]]; then
  aws s3 sync content/ "s3://$CONTENT_BUCKET/content/" --exclude '*' --include '*.md'
  log "\"step\":\"seeded_content\""
fi

# --- data directories (LibreChat runs as uid 1000 inside the container)
mkdir -p app/data/uploads app/data/images app/data/mongo
chown -R 1000:1000 app/data/uploads app/data/images

# --- build the gateway and start everything
docker build -q -t "suki-gateway:$APP_VERSION" app/gateway >/dev/null
COMPOSE=(docker compose --project-directory app -f app/docker-compose.yml)
"${COMPOSE[@]}" pull -q nginx mongodb
"${COMPOSE[@]}" up -d --remove-orphans

# --- wait until healthy (max ~3 minutes)
for i in $(seq 1 36); do
  if curl -fsS -m 3 http://127.0.0.1/health >/dev/null 2>&1 && curl -fsS -m 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    docker image prune -f >/dev/null   # old images are a classic disk filler
    log "\"result\":\"ok\",\"app_version\":\"$APP_VERSION\",\"librechat_image\":\"$LIBRECHAT_IMAGE\",\"seconds\":$((i*5))"
    exit 0
  fi
  sleep 5
done
"${COMPOSE[@]}" ps
log "\"result\":\"unhealthy\",\"app_version\":\"$APP_VERSION\""
exit 1
