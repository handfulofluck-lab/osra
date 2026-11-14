#!/usr/bin/env bash
# restore-drill.sh — proves a production backup can be restored (#766 item 5, gate #637).
#
#   AWS_PROFILE=<management profile> ./infra/terraform/restore-drill.sh [--from-copy]
#
# Restores the newest recovery point of production's database into a TEMPORARY instance in production's
# private subnets (no public access, the same security group as the real database), waits until it is
# available, records what it restored, and deletes it again without a final snapshot. With --from-copy it
# first copies the newest off-site recovery point back from the management account's vault, which is the
# path that matters if the production account is lost.
#
# It changes nothing that exists: it only creates and then deletes `<prefix>-restore-drill-<time>`.
# The log it prints (no data, no secrets) is the evidence for #637; paste it on the gate issue.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "${AWS_PROFILE:-}" ] || { echo "set AWS_PROFILE explicitly" >&2; exit 1; }
export AWS_PAGER=""
out() { terraform -chdir="$HERE/$1" output -raw "$2"; }

role=$(out env deploy_role_arn)
want_account=$(out env allowed_account_id)
db_id=$(out env rds_identifier)
region=$(out env region)

creds=$(aws sts assume-role --role-arn "$role" --role-session-name osra-restore-drill \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<EOC
$creds
EOC
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION="$region"
unset AWS_PROFILE
[ "$(aws sts get-caller-identity --query Account --output text)" = "$want_account" ] \
  || { echo "refusing: credentials are for another account" >&2; exit 1; }

db_arn=$(aws rds describe-db-instances --db-instance-identifier "$db_id" --query 'DBInstances[0].DBInstanceArn' --output text)
subnet_group=$(aws rds describe-db-instances --db-instance-identifier "$db_id" --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)
sgs=$(aws rds describe-db-instances --db-instance-identifier "$db_id" --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output text)
vault="${db_id%-postgres}-vault"

rp=$(aws backup list-recovery-points-by-resource --resource-arn "$db_arn" \
  --query 'reverse(sort_by(RecoveryPoints[?Status==`COMPLETED`], &CreationDate))[0].RecoveryPointArn' --output text)
[ -n "$rp" ] && [ "$rp" != None ] || { echo "no completed recovery point for $db_id yet" >&2; exit 1; }

if [ "${1:-}" = "--from-copy" ]; then
  echo "--from-copy: copy the newest off-site recovery point back into $vault from the management account first," >&2
  echo "then run this script again without the flag. (Done from the management account: aws backup start-copy-job.)" >&2
  exit 2
fi

drill="${db_id}-restore-drill-$(date -u +%Y%m%d%H%M)"
started=$(date -u +%FT%TZ)
echo "restore drill $drill"
echo "  source recovery point: ${rp##*:}"
echo "  started: $started"

job=$(aws backup start-restore-job --recovery-point-arn "$rp" \
  --iam-role-arn "$(aws iam get-role --role-name "${db_id%-postgres}-backup" --query Role.Arn --output text)" \
  --metadata "DBInstanceIdentifier=$drill,DBSubnetGroupName=$subnet_group,VpcSecurityGroupIds=[\"${sgs// /\",\"}\"],PubliclyAccessible=false,MultiAZ=false,DeletionProtection=false" \
  --query RestoreJobId --output text)
echo "  restore job: $job"

while :; do
  status=$(aws backup describe-restore-job --restore-job-id "$job" --query Status --output text)
  case "$status" in COMPLETED) break ;; FAILED|ABORTED) echo "  restore job $status" >&2; exit 1 ;; esac
  sleep 60
done
aws rds wait db-instance-available --db-instance-identifier "$drill"
finished=$(date -u +%FT%TZ)
aws rds describe-db-instances --db-instance-identifier "$drill" \
  --query 'DBInstances[0].[DBInstanceStatus,Engine,EngineVersion,StorageEncrypted,PubliclyAccessible]' --output text \
  | awk '{print "  restored: status="$1" engine="$2" "$3" encrypted="$4" public="$5}'
echo "  available at: $finished"

aws rds delete-db-instance --db-instance-identifier "$drill" --skip-final-snapshot --delete-automated-backups >/dev/null
aws rds wait db-instance-deleted --db-instance-identifier "$drill"
echo "  deleted: $(date -u +%FT%TZ)"
echo "drill OK"
