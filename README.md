# Suki — the Suklay & Kulay salon assistant

SAM10 Systems Administration and Maintenance final project by **Jansdale S. Yusi** and **Rhea Angeline G. Manipon**.

Suki is a reskinned [LibreChat](https://github.com/danny-avila/LibreChat) that answers customers' questions about a
**fictional** beauty salon (services, prices, hours, booking, policies, aftercare), in English, Filipino or Taglish.
It runs on AWS and is operated properly: monitoring, backups, security, automation and one practised incident.

| | |
|---|---|
| **Live system** | <https://suki-salon.duckdns.org> (sign up with any e-mail; per-user and per-IP rate limits apply) |
| **Project website** | <https://jansdale21.github.io/suki-salon-assistant/> |
| **Base system** | LibreChat v0.8.9 by Danny Avila and contributors, MIT licence. See [NOTICE.md](NOTICE.md) |
| **Model** | Google Gemini free tier through the Gemini API: `gemini-3.5-flash-lite`, with fallbacks `gemini-3-flash-preview`, `gemini-flash-lite-latest`, `gemini-3.7-flash`. No self-hosted model, no AWS AI service |
| **AWS** | Account 153079315475, region ap-southeast-1 (Singapore), CloudFormation stack `suki` |
| **Data** | All salon data is invented. No real people, phone numbers or addresses |

### Results at a glance (2026-11-27)

| Measure | Result |
|---|---|
| Test questions passed | 32 / 32 (100%), median answer 1.7 s |
| Restore drill | counts match, database restored in **41 s** (RPO up to 6 h) |
| Disk-full incident | detected in 7 min 41 s, fixed in 6 min 40 s, prevention proven |
| Health check | every 5 min, all OK outside the planned restore drill |
| Cost | US$5.63 month-to-date for the account (AWS credits); Suki ≈ US$1/day; Gemini ₱0 |

Full evidence: the [project website](https://jansdale21.github.io/suki-salon-assistant/).

---

## Architecture

Browser → **HTTPS** (`suki-salon.duckdns.org`, free **Let's Encrypt** certificate on nginx) → **EC2 t3.small** (Amazon Linux 2023, Docker:
nginx → LibreChat → MongoDB, plus the **Suki gateway**) → Google Gemini. The gateway reads the salon knowledge base from **S3** and every
secret from **SSM Parameter Store**. Logs and metrics go to **CloudWatch** (dashboard + 12 alarms → **SNS** e-mail). A **Lambda** health check
runs every 5 minutes. Backups go to S3 every 6 hours. **CloudTrail** audits the account; **AWS Budgets** watches cost.

### What changed during deployment (and why)

| Problem | What we did |
|---|---|
| CloudShell: "account verification is in progress" | Ran the same scripts from GitHub Codespaces with the AWS CLI, switching into the `SukiAdmin` role with an MFA code |
| GuardDuty: `SubscriptionRequiredException` | `deploy-stack.sh` skips GuardDuty when the account cannot use it yet |
| CloudFront: "Your account must be verified before you can add new CloudFront resources" | HTTPS moved onto nginx with Let's Encrypt and a free DuckDNS name (sslip.io was rejected: not on the Public Suffix List, so it shares one Let's Encrypt limit with everyone) |
| Gemini 503 "high demand" on the newest flash models | Main model `gemini-3.5-flash-lite`; the gateway retries fallback models on 429/5xx |
| First restore drill brought back an empty database (backup was older than our accounts) | Back up right after creating accounts; drill repeated successfully |
| Disk filled by a runaway debug log | `/var/log/suki` moved to its own capped 2 GiB volume |

---

## Repository map

| Path | What it is |
|---|---|
| `app/librechat.yaml` | The reskin: welcome text, theme colours, one fixed "Suki" assistant, features switched off, custom endpoint |
| `app/branding/` | Logo, icon, favicons and CSS (served by nginx in place of LibreChat's own) |
| `app/nginx/nginx.conf`, `suki-app.conf` | HTTPS (Let's Encrypt), HTTP→HTTPS redirect, branding, JSON access log, security headers. `nginx.local.conf` is the HTTP-only laptop version |
| `app/gateway/` | **Suki gateway** (Python/FastAPI): S3 knowledge base, PII redaction, fallback models, per-request logging, secrets from Parameter Store. Tests: `pytest` |
| `app/docker-compose.yml` | Production stack on EC2 (nginx, LibreChat, MongoDB, gateway; logs to CloudWatch) |
| `app/docker-compose.local.yml` | Laptop / Codespaces stack |
| `content/` | The salon knowledge base and Suki's system prompt (uploaded to S3) |
| `infra/cloudformation/suki-stack.yaml` | **All AWS infrastructure**: EC2, Elastic IP, S3, IAM, security group, SNS, log groups, metric filters, 12 alarms, dashboard, Budget, CloudTrail, GuardDuty (when allowed), health-check Lambda, GitHub OIDC role |
| `infra/scripts/` | `put-secrets.sh`, `deploy-stack.sh` (run from your machine), `bootstrap-instance.sh` and `deploy.sh` (run on EC2), `upload-content.sh` |
| `infra/cloudwatch/agent.json` | CloudWatch agent: memory/disk metrics, automation logs |
| `ops/backup/` | Backup to S3 every 6 hours and the restore drill |
| `ops/eval/` | 32 labelled test questions and the scoring script |
| `ops/fault/` | Disk-full fault injector, resolve marker, prevention (`prevention/isolate-log-volume.sh`) |
| `ops/tls/` | DuckDNS update and Let's Encrypt renewal |
| `ops/systemd/` | Timers: backup every 6 h, test run 03:00 and 15:00, certificate check daily (Asia/Manila) |
| `ops/evidence/collect-evidence.sh` | Read-only AWS commands whose output is evidence for the website |
| `.github/workflows/` | `deploy.yml` (push to main → test → S3 + redeploy via SSM), `secret-scan.yml` (gitleaks, full history), `pages.yml` (website) |
| `docs/` | The project website (GitHub Pages); screenshots in `docs/evidence/` |

---

## Run it locally (Codespaces or Docker Desktop)

Prerequisite: a Google AI Studio API key (free).

```bash
cd app
cp .env.local.example .env.local      # fill in the blanks (openssl rand -hex 32 / -hex 16)
docker compose -f docker-compose.local.yml --env-file .env.local up -d --build
# open http://localhost:8088 (in Codespaces: the forwarded port 8088)
```

Gateway tests: `cd app/gateway && pip install -r requirements.txt pytest && pytest -q`

## Deploy to AWS

Use your **own IAM user with MFA**, switched into the admin role, never the root account. From CloudShell, or from Codespaces with an AWS CLI
profile that assumes `SukiAdmin` with `mfa_serial` set.

```bash
export AWS_REGION=ap-southeast-1
./infra/scripts/put-secrets.sh        # app secrets + Gemini key (hidden input) into /suki/prod
aws ssm put-parameter --name /suki/prod/GEMINI_FALLBACK_MODELS --type String \
  --value "gemini-3-flash-preview,gemini-flash-lite-latest,gemini-3.7-flash"
aws ssm put-parameter --name /suki/prod/DUCKDNS_TOKEN --type SecureString --value "<duckdns token>"

ALERT_EMAIL=you@example.com \
PUBLIC_HOST=suki-salon.duckdns.org \
GIT_REPO_URL=https://github.com/jansdale21/suki-salon-assistant.git \
GITHUB_REPO=jansdale21/suki-salon-assistant \
./infra/scripts/deploy-stack.sh
```

Then: confirm the SNS e-mail; wait about 10 minutes (bootstrap log in CloudWatch `/suki/automation`); open the `PublicUrl` output.
Turn on GitHub Pages (Settings → Pages → Source: GitHub Actions) and store the website URL:
`aws ssm put-parameter --name /suki/prod/WEBSITE_URL --type String --value https://jansdale21.github.io/suki-salon-assistant/`

## Day-to-day operations

```bash
# EC2 → suki-app → Connect → Session Manager (no SSH), then:
sudo -i
cd /opt/suki && C="docker compose --project-directory app -f app/docker-compose.yml"
$C ps                                                       # containers
$C logs --tail 50 api                                       # LibreChat log (also CloudWatch /suki/app)
curl -s localhost:8080/healthz                              # gateway + knowledge version
$C exec api npm run create-user                             # make an account by hand
systemctl start suki-backup.service                         # backup now (do this after creating accounts)
bash ops/backup/restore-drill.sh --verify                   # safe restore test; --live for the real drill
systemctl start suki-eval.service                           # run the 32 test questions now
bash infra/scripts/deploy.sh --pull                         # redeploy latest main
```

Change the model without redeploying:
`aws ssm put-parameter --name /suki/prod/GEMINI_MODEL --value <model> --overwrite --type String`, then `$C restart gateway`.

**Cost and clean-up:** about US$1/day (t3.small, public IPv4, disk, CloudWatch), paid from AWS credits; Budget alert at US$30.
After grading: `aws cloudformation delete-stack --stack-name suki`, empty and delete the `suki-…` S3 buckets, delete the DuckDNS name,
the Gemini key and the IAM access key used from Codespaces, and tell the instructor. Our other app in the same account is not part of the stack.

---

## Contribution log

| Date | Who | What |
|---|---|---|
| 2026-11-22 | Both | Read the brief; chose LibreChat + Gemini; salon domain. |
| 2026-11-26 | Jansdale | Ran stock LibreChat and Suki in Codespaces (Docker Desktop unavailable); new logo; fixed Gemini 503 with fallback models |
| 2026-11-26 | Jansdale, Rhea | IAM users with MFA, `suki-team` group, `SukiAdmin` role (MFA required) |
| 2026-11-27 | Jansdale | Secrets in Parameter Store; deploy blocked (CloudShell, GuardDuty, CloudFront); HTTPS moved to Let's Encrypt + DuckDNS; stack deployed |
| 2026-11-27 | Jansdale, Rhea | Live test, eval 32/32, two restore drills, alarm test, disk-full incident and prevention, evidence screenshots |
| 2026-11-27 | Jansdale, Rhea | Video Presentation |
| 2026-11-27 | Rhea | Frontend Development |
