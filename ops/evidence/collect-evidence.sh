#!/usr/bin/env bash
# Prints read-only AWS facts for the website evidence (run from a laptop with your IAM user).
# Output contains no secrets, but CHECK IT before publishing (account IDs can be blurred).
#   ./ops/evidence/collect-evidence.sh > evidence-$(date +%F).txt
set -uo pipefail
REGION="${AWS_REGION:-ap-southeast-1}"; STACK="${STACK_NAME:-suki}"
run() { echo; echo "\$ $*"; "$@" 2>&1; }
run aws sts get-caller-identity --query '{Arn:Arn}'
run aws ec2 describe-instances --region "$REGION" --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,IMDSv2:MetadataOptions.HttpTokens,Tags:Tags[?Key==`Project`]|[0].Value}' --output table
run aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
  --query 'Volumes[].{Id:VolumeId,Size:Size,Encrypted:Encrypted}' --output table
B=$(aws ssm get-parameter --region "$REGION" --name /suki/prod/CONTENT_BUCKET --query Parameter.Value --output text)
run aws s3api get-bucket-versioning --bucket "$B"
run aws s3api get-public-access-block --bucket "$B"
run aws s3api get-bucket-lifecycle-configuration --bucket "$B" --query 'Rules[].{Id:ID,Days:Expiration.Days}'
run aws s3 ls "s3://$B/backups/mongo/" --recursive --human-readable
run aws ssm describe-parameters --region "$REGION" --parameter-filters Key=Path,Option=Recursive,Values=/suki/prod \
  --query 'Parameters[].{Name:Name,Type:Type,LastModified:LastModifiedDate}' --output table
run aws iam generate-credential-report
sleep 5
run bash -c "aws iam get-credential-report --query Content --output text | base64 -d | cut -d, -f1,4,8,9,11 | column -t -s,"
run aws iam list-users --query 'Users[].{User:UserName,Created:CreateDate}' --output table
run aws cloudtrail get-trail-status --region "$REGION" --name "$STACK-trail" --query '{IsLogging:IsLogging,LatestDelivery:LatestDeliveryTime}'
run aws guardduty list-detectors --region "$REGION"
run aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix suki- \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold,Updated:StateUpdatedTimestamp}' --output table
run aws logs describe-log-groups --region "$REGION" --log-group-name-prefix /suki --query 'logGroups[].{Group:logGroupName,RetentionDays:retentionInDays}' --output table
run aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK" \
  --query 'SecurityGroups[].IpPermissions[].{Port:FromPort,PrefixLists:PrefixListIds[].PrefixListId,Cidrs:IpRanges[].CidrIp}'
run aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Actual:CalculatedSpend.ActualSpend.Amount}' --output table
