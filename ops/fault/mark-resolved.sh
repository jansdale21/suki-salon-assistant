#!/usr/bin/env bash
# Record the moment you consider the incident fixed (for time-to-fix on the incident page).
#   sudo ops/fault/mark-resolved.sh "rotated and truncated noisy-debug.log, installed hourly logrotate"
set -euo pipefail
NOTE="${1:-resolved}"
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"fault_resolved\",\"disk_used_pct\":$(df --output=pcent / | tail -1 | tr -dc 0-9),\"note\":\"${NOTE//\"/}\"}" >> /var/log/suki/fault.log
tail -5 /var/log/suki/fault.log
