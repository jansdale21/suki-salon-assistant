#!/usr/bin/env bash
# Upload the salon knowledge base (content/*.md) to S3. The gateway re-reads S3 every 5 minutes,
# so content changes go live without a redeploy. Old versions stay in S3 (versioning) for rollback.
#   ./infra/scripts/upload-content.sh
set -euo pipefail
REGION="${AWS_REGION:-ap-southeast-1}"
BUCKET="$(aws ssm get-parameter --region "$REGION" --name /suki/prod/CONTENT_BUCKET --query Parameter.Value --output text)"
cd "$(dirname "$0")/../.."
aws s3 sync content/ "s3://$BUCKET/content/" --region "$REGION" --exclude '*' --include '*.md'
echo "Uploaded. Object versions:"
aws s3api list-object-versions --region "$REGION" --bucket "$BUCKET" --prefix content/ \
  --query 'Versions[?IsLatest].[Key,VersionId,LastModified]' --output table
