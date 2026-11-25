#!/usr/bin/env bash
# WS-F fault injection: a "debug logging left on" scenario that fills the root disk.
# A noisy process appends log lines to /var/log/suki/noisy-debug.log far faster than the daily
# logrotate can keep up. It stops by itself at TARGET% (default 97%) so Session Manager keeps working.
#
#   sudo ops/fault/inject-disk-fault.sh            # start (runs in the background)
#   sudo ops/fault/inject-disk-fault.sh --status   # show progress
#
# Then DON'T fix it straight away: let the alarm fire, investigate as if you did not know the cause
# (df -h, du, lsof, docker logs, CloudWatch), record times, then fix and prevent. See the runbook.
set -euo pipefail
TARGET="${TARGET:-97}"
LOG=/var/log/suki/fault.log
NOISY=/var/log/suki/noisy-debug.log
mkdir -p /var/log/suki
used() { df --output=pcent / | tail -1 | tr -dc '0-9'; }

if [[ "${1:-}" == "--status" ]]; then
  df -h /; ls -lh "$NOISY" 2>/dev/null || true; pgrep -af suki-noisy || echo "injector not running"; exit 0
fi

echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"fault_started\",\"type\":\"disk_full_noisy_log\",\"disk_used_pct\":$(used),\"target_pct\":$TARGET}" >> "$LOG"
nohup bash -c "exec -a suki-noisy bash -c '
  line=\"\$(date -u +%FT%TZ) DEBUG suki.worker cache-miss key=\$(head -c 400 /dev/urandom | base64 -w0)\"
  while [ \$(df --output=pcent / | tail -1 | tr -dc 0-9) -lt $TARGET ]; do
    for i in \$(seq 1 20000); do echo \"\$line\"; done >> $NOISY || break   # stop if the log filesystem is full
  done
  echo \"{\\\"ts\\\":\\\"\$(date -u +%FT%TZ)\\\",\\\"event\\\":\\\"fault_injector_stopped\\\",\\\"disk_used_pct\\\":\$(df --output=pcent / | tail -1 | tr -dc 0-9)}\" >> $LOG
'" >/dev/null 2>&1 &
echo "Fault injector started (pid $!). Disk now $(used)%. Watch the suki-ec2-disk-used-high alarm."
