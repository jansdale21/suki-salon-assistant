#!/usr/bin/env bash
# One-time setup of the EC2 instance. Called by the CloudFormation UserData after `git clone`.
# Safe to re-run. Every step here is also a deliberate operations decision (see comments).
set -euxo pipefail
set -a; source /etc/suki.env; set +a   # export AWS_REGION etc. to the aws CLI
cd "$SUKI_HOME"

# 1. Swap: t3.small has 2 GiB RAM; 2 GiB swap keeps LibreChat + MongoDB from being OOM-killed.
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

# 2. Log hygiene (prevention for the disk-full fault class).
mkdir -p /var/log/suki
cat > /etc/logrotate.d/suki <<'EOF'
/var/log/suki/*.log {
  weekly
  rotate 4
  maxsize 20M
  compress
  missingok
  notifempty
  copytruncate
}
EOF
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/suki.conf
systemctl restart systemd-journald
# Containers log to CloudWatch (awslogs driver); anything else is capped locally.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
systemctl restart docker

# 3. CloudWatch agent: memory, swap and disk metrics + automation log files.
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
  -c "file:$SUKI_HOME/infra/cloudwatch/agent.json"

# 4. Scheduled automations (systemd timers run with nobody touching them).
install -m 0644 ops/systemd/*.service ops/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now suki-backup.timer suki-eval.timer suki-cert-renew.timer

# 5. First deployment.
bash "$SUKI_HOME/infra/scripts/deploy.sh"
