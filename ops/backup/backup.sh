#!/usr/bin/env bash
# Scheduled backup (automation #2), run by suki-backup.timer every 6 hours (00/06/12/18 Asia/Manila).
# What it saves to s3://<bucket>/backups/ (bucket is versioned; lifecycle keeps 14 days):
#   mongo/<date>/suki-mongo-<ts>.archive.gz  - full mongodump of the LibreChat database
#   mongo/<date>/suki-mongo-<ts>.manifest.json - document counts, used to verify a restore
#   config/<date>/suki-config-<ts>.tar.gz     - librechat.yaml, nginx, branding, content, git commit
# Secrets are NOT copied: they already live in Parameter Store (their names go in the manifest).
set -euo pipefail
set -a; source /etc/suki.env; set +a   # export AWS_REGION etc. to the aws CLI
cd "$SUKI_HOME"
LOG=/var/log/suki/backup.log
TS="$(date -u +%Y%m%dT%H%M%SZ)"; DAY="$(date -u +%Y/%m/%d)"
TMP="$(mktemp -d /var/tmp/suki-backup.XXXX)"
trap 'rm -rf "$TMP"' EXIT
log() { echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"backup\",$1}" | tee -a "$LOG"; }
fail() {
  log "\"result\":\"failed\",\"reason\":\"$1\""
  aws sns publish --topic-arn "$ALERT_TOPIC_ARN" --subject "Suki backup FAILED ($TS)" \
    --message "Scheduled backup failed: $1. See CloudWatch Logs /suki/automation." >/dev/null || true
  exit 1
}
trap 'fail "error on line $LINENO"' ERR
COMPOSE=(docker compose --project-directory app -f app/docker-compose.yml)
START=$(date +%s)

# 1. Database dump (credentials come from the container's own environment)
"${COMPOSE[@]}" exec -T mongodb sh -c \
  'mongodump --quiet --uri "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/?authSource=admin" --db LibreChat --archive --gzip' \
  > "$TMP/db.archive.gz"
SIZE=$(stat -c %s "$TMP/db.archive.gz")
[[ "$SIZE" -gt 100 ]] || fail "dump is empty ($SIZE bytes)"

# 2. Manifest with document counts (for restore verification)
COUNTS=$("${COMPOSE[@]}" exec -T mongodb sh -c \
  'mongosh --quiet "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/LibreChat?authSource=admin" --eval "JSON.stringify({users: db.users.countDocuments(), conversations: db.conversations.countDocuments(), messages: db.messages.countDocuments()})"')
PARAMS=$(aws ssm get-parameters-by-path --path "$PARAM_PREFIX" --query 'Parameters[].Name' --output json | tr -d '\n ')
cat > "$TMP/manifest.json" <<EOF
{"timestamp":"$TS","app_version":"$(git rev-parse --short HEAD)","dump_bytes":$SIZE,"counts":$COUNTS,"parameter_names":$PARAMS}
EOF

# 3. Configuration snapshot (no secrets: app/.env is excluded)
tar -czf "$TMP/config.tar.gz" --exclude='app/.env' --exclude='app/data' \
  app/librechat.yaml app/docker-compose.yml app/nginx app/branding content infra ops

# 4. Upload
BASE="s3://$CONTENT_BUCKET/backups"
aws s3 cp --quiet "$TMP/db.archive.gz"  "$BASE/mongo/$DAY/suki-mongo-$TS.archive.gz"
aws s3 cp --quiet "$TMP/manifest.json"  "$BASE/mongo/$DAY/suki-mongo-$TS.manifest.json"
aws s3 cp --quiet "$TMP/config.tar.gz"  "$BASE/config/$DAY/suki-config-$TS.tar.gz"

# 5. Tell CloudWatch it worked (the suki-backup-missing alarm watches this)
aws cloudwatch put-metric-data --namespace Suki --metric-data \
  "MetricName=BackupSucceeded,Value=1,Unit=Count" "MetricName=BackupSizeBytes,Value=$SIZE,Unit=Bytes"
log "\"result\":\"ok\",\"key\":\"backups/mongo/$DAY/suki-mongo-$TS.archive.gz\",\"bytes\":$SIZE,\"counts\":$COUNTS,\"seconds\":$(( $(date +%s) - START ))"
