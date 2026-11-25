#!/usr/bin/env bash
# Create or update the whole AWS stack from your laptop.
#   ALERT_EMAIL=you@example.com GIT_REPO_URL=https://github.com/you/suki-salon-assistant.git \
#   [GITHUB_REPO=you/suki-salon-assistant] ./infra/scripts/deploy-stack.sh
# Uses the default VPC and its first public subnet unless VPC_ID / SUBNET_ID are set.
set -euo pipefail
REGION="${AWS_REGION:-ap-southeast-1}"
STACK="${STACK_NAME:-suki}"
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${ALERT_EMAIL:?set ALERT_EMAIL}"
: "${GIT_REPO_URL:?set GIT_REPO_URL (public HTTPS clone URL of your repo)}"

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)}"
SUBNET_ID="${SUBNET_ID:-$(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}"
PL_ID="$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)"
GD_EXISTING="$(aws guardduty list-detectors --region "$REGION" --query 'length(DetectorIds)' --output text)"
ENABLE_GD=$([[ "$GD_EXISTING" == "0" ]] && echo true || echo false)
OIDC_EXISTING="$(aws iam list-open-id-connect-providers --query \
  "length(OpenIDConnectProviderList[?ends_with(Arn,'token.actions.githubusercontent.com')])" --output text)"
CREATE_OIDC=$([[ "$OIDC_EXISTING" == "0" ]] && echo true || echo false)

echo "Region=$REGION Stack=$STACK VPC=$VPC_ID Subnet=$SUBNET_ID CloudFrontPL=$PL_ID GuardDuty-new=$ENABLE_GD OIDC-new=$CREATE_OIDC"
for p in CREDS_KEY CREDS_IV JWT_SECRET JWT_REFRESH_SECRET MONGO_PASSWORD GATEWAY_TOKEN GEMINI_API_KEY; do
  aws ssm get-parameter --region "$REGION" --name "/suki/prod/$p" >/dev/null 2>&1 \
    || { echo "Missing /suki/prod/$p - run infra/scripts/put-secrets.sh first"; exit 1; }
done

aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
  --template-file "$HERE/../cloudformation/suki-stack.yaml" \
  --capabilities CAPABILITY_IAM \
  --tags Project=SAM10 Team="${TEAM_TAG:-Yusi-Manipon}" App=suki \
  --parameter-overrides \
    AlertEmail="$ALERT_EMAIL" GitRepoUrl="$GIT_REPO_URL" GitBranch="${GIT_BRANCH:-main}" \
    VpcId="$VPC_ID" SubnetId="$SUBNET_ID" CloudFrontPrefixListId="$PL_ID" \
    InstanceType="${INSTANCE_TYPE:-t3.small}" MonthlyBudgetUSD="${BUDGET_USD:-30}" \
    GitHubRepo="${GITHUB_REPO:-}" CreateGitHubOidcProvider="$CREATE_OIDC" EnableGuardDuty="$ENABLE_GD" \
    TeamTag="${TEAM_TAG:-Yusi-Manipon}"

aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
echo "Next: confirm the SNS subscription e-mail, wait ~10 minutes for the instance to finish bootstrapping,"
echo "then open the PublicUrl. Bootstrap log: CloudWatch Logs /suki/automation (stream <instance>-bootstrap)."
