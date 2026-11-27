# Suki — the Suklay & Kulay salon assistant

SAM10 Systems Administration and Maintenance final project by **Jansdale S. Yusi** and **Rhea Angeline G. Manipon**.

Suki is a reskinned [LibreChat](https://github.com/danny-avila/LibreChat) that answers customers' questions about a
**fictional** beauty salon (services, prices, hours, booking, policies, aftercare), in English, Filipino or Taglish.
It runs on AWS and is operated properly: monitoring, backups, security, automation and one practised incident.

- Live system: `https://suki-salon.duckdns.org`
- Project website: `https://jansdale21.github.io/suki-salon-assistant/`
- Base system: LibreChat by Danny Avila and contributors, MIT licence. See [NOTICE.md](NOTICE.md).
- Model: Google Gemini (free tier) through the Gemini API. We do not host a model, and no AWS AI service is used.
- All salon data is invented. No real people, phone numbers or addresses.

---

## Repository map

| Path | What it is |
|---|---|
| `app/librechat.yaml` | The reskin: welcome text, theme colours, one fixed "Suki" assistant, features switched off, custom endpoint |
| `app/branding/` | Logo and favicons (served by nginx over LibreChat's own) |
| `app/nginx/nginx.conf` | Reverse proxy: branding, JSON access log, security headers |
| `app/gateway/` | **Suki gateway** (Python/FastAPI): S3 knowledge base, PII redaction, per-request logging, Gemini key from Parameter Store. Unit tests: `pytest` |
| `app/docker-compose.yml` | Production stack on EC2 (nginx, LibreChat, MongoDB, gateway; logs to CloudWatch) |
| `app/docker-compose.local.yml` | Laptop stack for week 1 |
| `content/` | The salon knowledge base and Suki's system prompt (uploaded to S3) |
| `infra/cloudformation/suki-stack.yaml` | **All AWS infrastructure**: EC2, EIP, CloudFront, S3, IAM, SG, SNS, log groups, metric filters, 12 alarms, dashboard, Budget, CloudTrail, GuardDuty, health-check Lambda, GitHub OIDC role |
| `infra/scripts/` | `put-secrets.sh` (laptop), `deploy-stack.sh` (laptop), `bootstrap-instance.sh` and `deploy.sh` (EC2), `upload-content.sh` |
| `infra/cloudwatch/agent.json` | CloudWatch agent: memory/disk metrics, automation logs |
| `ops/backup/` | Backup to S3 every 6 hours and the restore drill |
| `ops/eval/` | 32 labelled test questions and the scoring script |
| `ops/fault/` | Disk-full fault injector, resolve marker, candidate prevention (`prevention/isolate-log-volume.sh`) |
| `ops/systemd/` | Timers for the backup (every 6 h) and test run (03:00 and 15:00), Asia/Manila |
| `ops/evidence/collect-evidence.sh` | Read-only AWS commands whose output is evidence for the website |
| `.github/workflows/` | `deploy.yml` (push to main → test → S3 + redeploy via SSM), `secret-scan.yml` (gitleaks, full history), `pages.yml` (website) |
| `docs/` | The project website (GitHub Pages). Every `EVIDENCE NEEDED` box must be replaced with real evidence |

---

## Week 1 — run it locally

Prerequisites: Docker Desktop, a Google AI Studio API key (free).

```bash
cd app
cp .env.local.example .env.local      # fill in the blanks (openssl rand -hex 32 / -hex 16)
docker compose -f docker-compose.local.yml --env-file .env.local up -d --build
open http://localhost:8088            # register a test account (invented name, @example.com e-mail)
```

Gateway tests: `cd app/gateway && pip install -r requirements.txt pytest && pytest -q`

Before you reskin anything, also run **stock** LibreChat once (upstream quick start) and take the "before" screenshot (E-05) and baseline numbers.

## Week 2 — deploy to AWS

Do these as your **own IAM user with MFA**, never the root account.

1. **Account hygiene (day one):** MFA on root and on both IAM users; no shared logins; an admin role you switch into when needed.
2. **Secrets into Parameter Store:**
   ```bash
   export AWS_REGION=ap-southeast-1
   ./infra/scripts/put-secrets.sh          # generates app secrets, asks for the Gemini key (hidden input)
   ```
3. **Push this repository to GitHub as a public repo** (the instance clones it; it contains no secrets — `secret-scan.yml` proves it).
4. **Create the stack:**
   ```bash
   ALERT_EMAIL=your-real-inbox@example.com \
   GIT_REPO_URL=https://github.com/<you>/suki-salon-assistant.git \
   GITHUB_REPO=<you>/suki-salon-assistant \
   ./infra/scripts/deploy-stack.sh
   ```
5. **Confirm the SNS e-mail** ("AWS Notification - Subscription Confirmation"). No confirmation = no alerts.
6. Wait about 10 minutes, open the `PublicUrl` output. Bootstrap log: CloudWatch Logs `/suki/automation`, stream `<instance-id>-bootstrap`.
7. **Create the user accounts** (registration is closed):
   ```bash
   aws ssm start-session --target <InstanceId>
   sudo docker compose --project-directory /opt/suki/app -f /opt/suki/app/docker-compose.yml exec api npm run create-user
   ```
8. Put the project website URL in Parameter Store (it becomes the app's Help link):
   `aws ssm put-parameter --name /suki/prod/WEBSITE_URL --type String --value https://<you>.github.io/suki-salon-assistant/`
   Also replace `jansdale21` in `app/librechat.yaml` (privacy policy link), commit, and redeploy.
9. Optional S-band auto-deploy: add the repository variables listed at the top of `.github/workflows/deploy.yml`.
10. Turn on GitHub Pages (Settings → Pages → Source: GitHub Actions).

If the LibreChat container logs a config error, compare `app/librechat.yaml` with that release's `librechat.example.yaml`. The deploy script
tries `registry.librechat.ai/librechat-ai/librechat:v0.8.9`, then `ghcr.io/danny-avila/librechat:v0.8.9`, then the dev image; pin your
choice with `aws ssm put-parameter --name /suki/prod/LIBRECHAT_IMAGE --type String --value <image>`.

## Week 3 — monitor and back up

- Dashboard **Suki-Operations** and the 12 `suki-*` alarms exist after step 4. Trigger one on purpose (e.g. stop the app for 10 min → `suki-healthcheck-failed`) and screenshot the e-mail (E-08).
- Backups run every 6 hours. Run one now: `sudo systemctl start suki-backup.service && tail /var/log/suki/backup.log`
- Restore test, early: `sudo /opt/suki/ops/backup/restore-drill.sh --verify`, then the real one, `--live` (E-11).

## Week 4 — automate and fix

- Check the timers: `systemctl list-timers 'suki-*'`. You need two unattended runs of each; they have been running since week 2.
- Fault: `sudo /opt/suki/ops/fault/inject-disk-fault.sh`, then investigate **without** looking at the script, as if it were real. Record times,
  find the root cause, fix it, `sudo /opt/suki/ops/fault/mark-resolved.sh "what you did"`, add a prevention, re-run to prove it, finish the runbook.

## Week 5 — publish and present

Replace every `EVIDENCE NEEDED`, `todo` and `DRAFT` marker on the website (`./docs/check-evidence.sh` lists what is left), record the
video, sign the declaration, then ZIP the repository **including `.git`**.

### Schedule

We are doing the whole project in **2 days** (see our step-by-step guide). The backup runs every 6 hours and the test run every 12 hours,
so every automation has at least two unattended runs by the morning of day 2. Before/after measurements use two 4-hour windows at the
same time of day (day 1 and day 2).

---|---|---|
| 1 | Nov 23 – Nov 29 | Running locally, reskin done, baseline captured, README log started |
| 2 | Nov 30 – Dec 6 | Deployed over HTTPS, secrets in Parameter Store, MFA, first Well-Architected pass, website started |
| 3 | Dec 7 – Dec 13 | Dashboard, alarms, real alert e-mail, backups running, restore tested |
| 4 | Dec 14 – Dec 20 | Automations proven (2+ runs each), fault + root cause + prevention + runbook, second Well-Architected pass |
| 5 | Dec 21 – Dec 27 | Results with before/after numbers, website finished, video, submission |

---

## Day-to-day operations

```bash
aws ssm start-session --target <InstanceId>                 # shell, no SSH
cd /opt/suki && C="docker compose --project-directory app -f app/docker-compose.yml"
sudo $C ps                                                  # containers
sudo $C logs --tail 50 api                                  # LibreChat log (also in CloudWatch /suki/app)
curl -s localhost:8080/healthz                              # gateway + knowledge version
sudo infra/scripts/deploy.sh --pull                         # redeploy latest main
./infra/scripts/upload-content.sh                           # (laptop) push content/ to S3; live within 5 min
aws ssm put-parameter --name /suki/prod/GEMINI_MODEL --value <model> --overwrite --type String  # then: sudo $C restart gateway
python3 ops/eval/run_eval.py                                # test questions now
```

**Cost:** a t3.small in Singapore is about US$0.0264/hour (roughly US$19/month if left on 24/7). With the public IPv4 address,
disk and custom metrics, expect roughly US$25–30/month. The default Budget alert is US$30. Stop the instance when not needed, and
**delete the stack at the end of term** (`aws cloudformation delete-stack --stack-name suki`; the S3 buckets are retained, so empty and delete them too),
delete the Gemini key in Google AI Studio, and tell the instructor.

---

## Contribution log (evidence for individual marks)

Keep this up to date every week. One line per meaningful piece of work.

| Week | Date | Who | What |
|---|---|---|---|
| 1 | 2026-11-22 | Both | Read the brief; chose LibreChat + Gemini; salon domain. Generated the project scaffold with Claude (declared on the website) |
| 1 | | Jansdale | |
| 1 | | Rhea | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
