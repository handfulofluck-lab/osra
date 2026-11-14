#!/usr/bin/env bash
# restore-drill.sh — proves a production backup can be restored (#766 item 5, gate #637).
#
#   AWS_PROFILE=<management profile> ./infra/terraform/restore-drill.sh              # in production
#   AWS_PROFILE=<management profile> ./infra/terraform/restore-drill.sh --from-copy  # from the off-site copy
#
# Default: restores the newest recovery point of production's database into a TEMPORARY instance in
# production's private subnets (no public access, the same security group as the real database), waits until
# it is available, records what it restored, and deletes it again without a final snapshot.
#
# --from-copy: the path that matters if the production account is lost. Runs in the MANAGEMENT account and
# the copy region: restores the newest COMPLETED recovery point in `osra-production-copy` into the isolated
# drill network org-audit creates there (no internet gateway, no ingress), then deletes it. It also proves the
# two KMS policies and the vault policy let a copy be made and read back.
#
# Either way it only creates and then deletes `<name>-restore-drill-<time>`. A trap deletes that instance on
# ANY exit once the restore job has started (failure, timeout, Ctrl-C), so a copy of production's data is
# never left running. Every wait has a ceiling. The log (no data, no secrets) is the #637 evidence.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "${AWS_PROFILE:-}" ] || { echo "set AWS_PROFILE explicitly" >&2; exit 1; }
export AWS_PAGER=""
out() { terraform -chdir="$HERE/$1" output -raw "$2"; }

mode=production
case "${1:-}" in
  "") ;;
  --from-copy) mode=copy ;;
  *) echo "usage: $0 [--from-copy]" >&2; exit 2 ;;
esac

RESTORE_TIMEOUT_MIN="${RESTORE_TIMEOUT_MIN:-120}"

if [ "$mode" = production ]; then
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
  restore_role=$(aws iam get-role --role-name "${db_id%-postgres}-backup" --query Role.Arn --output text)
  rp=$(aws backup list-recovery-points-by-resource --resource-arn "$db_arn" \
    --query 'reverse(sort_by(RecoveryPoints[?Status==`COMPLETED`], &CreationDate))[0].RecoveryPointArn' --output text)
  name="$db_id"
else
  # Management account, copy region, values from the org-audit stack.
  export AWS_REGION
  AWS_REGION=$(out org-audit backup_copy_region)
  want_account=$(out org-audit management_account_id)
  [ "$(aws sts get-caller-identity --query Account --output text)" = "$want_account" ] \
    || { echo "refusing: --from-copy runs with the management account's profile" >&2; exit 1; }
  vault=$(out org-audit backup_copy_vault_name)
  subnet_group=$(out org-audit restore_drill_subnet_group)
  sgs=$(out org-audit restore_drill_security_group)
  restore_role=$(out org-audit restore_drill_role_arn)
  rp=$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
    --query 'reverse(sort_by(RecoveryPoints[?Status==`COMPLETED`], &CreationDate))[0].RecoveryPointArn' --output text)
  name="osra-production-copy"
  echo "copy jobs into $vault (newest 3):"
  aws backup list-copy-jobs --by-destination-vault-arn "$(out org-audit backup_copy_vault_arn)" \
    --query 'reverse(sort_by(CopyJobs, &CreationDate))[:3].[CreationDate,State,SourceBackupVaultArn]' --output text \
    | awk '{print "  "$1" "$2" from "$3}' || true
fi

[ -n "$rp" ] && [ "$rp" != None ] || { echo "no completed recovery point yet ($mode)" >&2; exit 1; }

drill="${name}-restore-drill-$(date -u +%Y%m%d%H%M)"
echo "restore drill $drill ($mode, $AWS_REGION)"
echo "  source recovery point: ${rp##*:}"
echo "  started: $(date -u +%FT%TZ)"

cleanup() {
  status=$?
  if aws rds describe-db-instances --db-instance-identifier "$drill" >/dev/null 2>&1; then
    echo "  cleanup: deleting $drill (exit status $status)"
    aws rds delete-db-instance --db-instance-identifier "$drill" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
    aws rds wait db-instance-deleted --db-instance-identifier "$drill" 2>/dev/null \
      && echo "  deleted: $(date -u +%FT%TZ)" \
      || echo "  WARNING: $drill may still exist; delete it by hand" >&2
  fi
  exit "$status"
}

job=$(aws backup start-restore-job --recovery-point-arn "$rp" --iam-role-arn "$restore_role" \
  --metadata "DBInstanceIdentifier=$drill,DBSubnetGroupName=$subnet_group,VpcSecurityGroupIds=[\"${sgs// /\",\"}\"],PubliclyAccessible=false,MultiAZ=false,DeletionProtection=false" \
  --query RestoreJobId --output text)
trap cleanup EXIT INT TERM
echo "  restore job: $job"

deadline=$(( $(date +%s) + RESTORE_TIMEOUT_MIN * 60 ))
while :; do
  status=$(aws backup describe-restore-job --restore-job-id "$job" --query Status --output text)
  case "$status" in
    COMPLETED) break ;;
    FAILED|ABORTED) echo "  restore job $status: $(aws backup describe-restore-job --restore-job-id "$job" --query StatusMessage --output text)" >&2; exit 1 ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || { echo "  restore job still $status after ${RESTORE_TIMEOUT_MIN} min" >&2; exit 1; }
  sleep 60
done
aws rds wait db-instance-available --db-instance-identifier "$drill"
aws rds describe-db-instances --db-instance-identifier "$drill" \
  --query 'DBInstances[0].[DBInstanceStatus,Engine,EngineVersion,StorageEncrypted,PubliclyAccessible]' --output text \
  | awk '{print "  restored: status="$1" engine="$2" "$3" encrypted="$4" public="$5}'
echo "  available at: $(date -u +%FT%TZ)"
echo "drill OK"
# The EXIT trap deletes the instance and prints the time.
