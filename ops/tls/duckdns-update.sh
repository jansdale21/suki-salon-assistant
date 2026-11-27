#!/usr/bin/env bash
# Point <name>.duckdns.org at this server's public IP and wait until DNS answers with it.
# Does nothing when the public URL is not a DuckDNS name. Token: /suki/prod/DUCKDNS_TOKEN (SecureString).
#   duckdns-update.sh <host>
set -euo pipefail
HOST="${1:?host}"
[[ "$HOST" == *.duckdns.org ]] || exit 0
NAME="${HOST%.duckdns.org}"
TOKEN="$(aws ssm get-parameter --name "$PARAM_PREFIX/DUCKDNS_TOKEN" --with-decryption --query Parameter.Value --output text)"
T=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
IP=$(curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/public-ipv4)
RESULT="$(curl -fsS -m 15 "https://www.duckdns.org/update?domains=${NAME}&token=${TOKEN}&ip=${IP}" || echo FAIL)"
echo "{\"event\":\"duckdns_update\",\"host\":\"$HOST\",\"ip\":\"$IP\",\"result\":\"$RESULT\"}"
[[ "$RESULT" == OK* ]] || exit 1
for i in $(seq 1 24); do   # up to 2 minutes
  [[ "$(getent ahostsv4 "$HOST" | awk 'NR==1{print $1}')" == "$IP" ]] && exit 0
  sleep 5
done
echo "{\"event\":\"duckdns_update\",\"host\":\"$HOST\",\"warning\":\"DNS not showing $IP yet\"}"
