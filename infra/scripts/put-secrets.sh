#!/usr/bin/env bash
# Run ONCE from your laptop (with your own IAM user + MFA session) BEFORE deploying the stack.
# Creates every secret Suki needs as an SSM Parameter Store SecureString under /suki/prod.
# Nothing is printed and nothing is written to disk. Existing values are kept unless --rotate.
#
#   ./infra/scripts/put-secrets.sh                # create missing secrets, ask for the Gemini key
#   ./infra/scripts/put-secrets.sh --rotate-gemini # replace only the Gemini key
set -euo pipefail
REGION="${AWS_REGION:-ap-southeast-1}"
PREFIX="/suki/prod"
TAGS="Key=Project,Value=SAM10 Key=App,Value=suki"

exists() { aws ssm get-parameter --region "$REGION" --name "$PREFIX/$1" >/dev/null 2>&1; }

put_secure() { # name value
  aws ssm put-parameter --region "$REGION" --name "$PREFIX/$1" --type SecureString \
    --value "$2" --overwrite >/dev/null
  aws ssm add-tags-to-resource --region "$REGION" --resource-type Parameter \
    --resource-id "$PREFIX/$1" --tags $TAGS >/dev/null
  echo "  stored $PREFIX/$1 (SecureString)"
}

generate() { # name bytes
  if exists "$1"; then echo "  kept   $PREFIX/$1 (already exists)"; else put_secure "$1" "$(openssl rand -hex "$2")"; fi
}

echo "Region: $REGION   Caller: $(aws sts get-caller-identity --query Arn --output text)"

if [[ "${1:-}" != "--rotate-gemini" ]]; then
  echo "Generating LibreChat and internal secrets..."
  generate CREDS_KEY 32
  generate CREDS_IV 16
  generate JWT_SECRET 32
  generate JWT_REFRESH_SECRET 32
  generate MONGO_PASSWORD 24
  generate GATEWAY_TOKEN 32
  if ! exists MONGO_USER; then
    aws ssm put-parameter --region "$REGION" --name "$PREFIX/MONGO_USER" --type String --value suki_admin >/dev/null
    echo "  stored $PREFIX/MONGO_USER (String)"
  fi
fi

if [[ "${1:-}" == "--rotate-gemini" ]] || ! exists GEMINI_API_KEY; then
  echo
  echo "Paste your Google AI Studio (Gemini) API key. Input is hidden."
  echo "Tip: restrict the key to the Generative Language API in Google Cloud and set an expiry if offered."
  read -rs -p "Gemini API key: " GKEY; echo
  [[ -n "$GKEY" ]] || { echo "No key entered"; exit 1; }
  put_secure GEMINI_API_KEY "$GKEY"
  unset GKEY
fi

echo
echo "Done. Parameter names (values are never printed):"
aws ssm get-parameters-by-path --region "$REGION" --path "$PREFIX" --query 'Parameters[].[Name,Type]' --output table
