#!/usr/bin/env bash
# Restore test for WS-C. Two modes:
#
#   sudo ops/backup/restore-drill.sh --verify [s3-key]
#       Non-destructive. Restores a backup into a throw-away MongoDB container and compares
#       document counts with the backup's manifest. Production keeps running.
#
#   sudo ops/backup/restore-drill.sh --live [s3-key]
#       The real disaster-recovery drill. Simulates losing the database: stops the app, moves the
#       live data directory aside (NOT deleted, so you can undo), starts an empty MongoDB, restores
#       from S3, restarts the app and verifies. Prints the measured RTO. Then log in and check
#       your test conversations are back (screenshot = evidence E-11).
#
# Without an s3-key the newest backup is used. Output goes to /var/log/suki/restore.log.
set -euo pipefail
set -a; source /etc/suki.env; set +a   # export AWS_REGION etc. to the aws CLI
cd "$SUKI_HOME"
MODE="${1:---verify}"; KEY="${2:-}"
LOG=/var/log/suki/restore.log
log() { echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"restore\",\"mode\":\"${MODE#--}\",$1}" | tee -a "$LOG"; }
COMPOSE=(docker compose --project-directory app -f app/docker-compose.yml)
set -a; source app/.env; set +a
START=$(date +%s)

if [[ -z "$KEY" ]]; then
  KEY=$(aws s3 ls "s3://$CONTENT_BUCKET/backups/mongo/" --recursive | grep '\.archive\.gz$' | sort | tail -1 | awk '{print $4}')
fi
[[ -n "$KEY" ]] || { echo "No backup found"; exit 1; }
MANIFEST_KEY="${KEY%.archive.gz}.manifest.json"
TMP="$(mktemp -d /var/tmp/suki-restore.XXXX)"; trap 'rm -rf "$TMP"' EXIT
aws s3 cp --quiet "s3://$CONTENT_BUCKET/$KEY" "$TMP/db.archive.gz"
aws s3 cp --quiet "s3://$CONTENT_BUCKET/$MANIFEST_KEY" "$TMP/manifest.json"
EXPECTED=$(jq -c .counts "$TMP/manifest.json")
log "\"step\":\"downloaded\",\"key\":\"$KEY\",\"expected\":$EXPECTED"

count_docs() { # container uri-host
  docker exec "$1" mongosh --quiet "mongodb://$MONGO_USER:$MONGO_PASSWORD@localhost:27017/LibreChat?authSource=admin" \
    --eval 'JSON.stringify({users: db.users.countDocuments(), conversations: db.conversations.countDocuments(), messages: db.messages.countDocuments()})'
}

if [[ "$MODE" == "--verify" ]]; then
  docker rm -f suki-restore-test >/dev/null 2>&1 || true
  docker run -d --name suki-restore-test -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
    -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASSWORD" docker.io/library/mongo:8.0.20 >/dev/null
  for i in $(seq 1 30); do docker exec suki-restore-test mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break; sleep 2; done
  docker exec -i suki-restore-test mongorestore --quiet --uri "mongodb://$MONGO_USER:$MONGO_PASSWORD@localhost:27017/?authSource=admin" \
    --archive --gzip < "$TMP/db.archive.gz"
  GOT=$(count_docs suki-restore-test)
  docker rm -f suki-restore-test >/dev/null
elif [[ "$MODE" == "--live" ]]; then
  read -r -p "This stops Suki and restores the database from $KEY. Type RESTORE to continue: " ok
  [[ "$ok" == "RESTORE" ]] || exit 1
  "${COMPOSE[@]}" stop api mongodb
  ASIDE="app/data/mongo.before-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  mv app/data/mongo "$ASIDE" && mkdir -p app/data/mongo
  log "\"step\":\"live_data_moved_aside\",\"path\":\"$ASIDE\""
  "${COMPOSE[@]}" up -d mongodb
  MCID=$("${COMPOSE[@]}" ps -q mongodb)
  for i in $(seq 1 30); do docker exec "$MCID" mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break; sleep 2; done
  sleep 3
  docker exec -i "$MCID" mongorestore --quiet --drop --uri "mongodb://$MONGO_USER:$MONGO_PASSWORD@localhost:27017/?authSource=admin" \
    --archive --gzip < "$TMP/db.archive.gz"
  GOT=$(count_docs "$MCID")
  "${COMPOSE[@]}" up -d
  for i in $(seq 1 36); do curl -fsS -m 3 http://127.0.0.1/health >/dev/null 2>&1 && break; sleep 5; done
  echo "Undo (if needed): stop the stack, then  mv $ASIDE app/data/mongo  and start again."
else
  echo "usage: $0 --verify|--live [s3-key]"; exit 2
fi

SECS=$(( $(date +%s) - START ))
MATCH=$([[ "$(echo "$GOT" | jq -cS .)" == "$(echo "$EXPECTED" | jq -cS .)" ]] && echo true || echo false)
log "\"result\":\"$([[ $MATCH == true ]] && echo ok || echo mismatch)\",\"key\":\"$KEY\",\"expected\":$EXPECTED,\"restored\":$GOT,\"counts_match\":$MATCH,\"rto_seconds\":$SECS"
echo
echo "Expected counts: $EXPECTED"
echo "Restored counts: $GOT"
echo "Match: $MATCH   Elapsed: ${SECS}s"
[[ "$MATCH" == true ]]
