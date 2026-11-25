#!/usr/bin/env bash
# Candidate prevention for the disk-full incident: give /var/log/suki its own capped filesystem,
# so a runaway log can fill ONLY that volume (default 2 GiB), never the root disk that MongoDB needs.
# (The classic "separate /var/log partition" practice, done with a loopback file.)
# Install it only AFTER you have investigated and confirmed the root cause yourselves. Then prove it:
#   sudo ops/fault/inject-disk-fault.sh   -> the log volume fills to 100% and the injector stops,
#   df -h / /var/log/suki                 -> the root disk stays well below the 85% alarm line.
set -euo pipefail
SIZE="${SIZE:-2G}"
IMG=/var/lib/suki-logvol.img
MNT=/var/log/suki
if mountpoint -q "$MNT"; then echo "$MNT is already its own filesystem"; df -h "$MNT"; exit 0; fi

pkill -f suki-noisy 2>/dev/null || true
# 1. Build the new filesystem first; nothing in /var/log/suki is touched until it exists.
[[ -f "$IMG" ]] || { fallocate -l "$SIZE" "$IMG" && mkfs.xfs -q "$IMG"; } || { rm -f "$IMG"; echo "could not create $IMG"; exit 1; }
# 2. Copy current logs onto it through a temporary mount.
STAGE="$(mktemp -d /mnt/suki-logvol.XXXX)"
mount -o loop "$IMG" "$STAGE"
mkdir -p "$MNT"
cp -a "$MNT/." "$STAGE/"
umount "$STAGE" && rmdir "$STAGE"
# 3. Only now free the root-disk copies and mount the volume in their place.
find "$MNT" -mindepth 1 -delete
mount -o loop "$IMG" "$MNT"
grep -q "$IMG" /etc/fstab || echo "$IMG $MNT xfs loop,defaults,nofail 0 0" >> /etc/fstab
systemctl restart amazon-cloudwatch-agent                         # re-open the log files it tails
echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"event\":\"prevention_installed\",\"type\":\"log_volume\",\"size\":\"$SIZE\"}" >> "$MNT/fault.log"
df -h / "$MNT"
