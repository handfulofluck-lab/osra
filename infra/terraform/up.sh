#!/bin/sh
# Bring up the on-demand staging stack: base (idempotent), env (per session), then schema + seed.
#
#   ./infra/terraform/up.sh                 # from the repo root
#   ./infra/terraform/up.sh -auto-approve   # any extra args go to every apply
#
# Why the seed step is a one-off ECS task: the RDS instance is private (no public IP, no route
# from a workstation), so `prisma migrate deploy` must run inside the VPC. The task definition
# already injects DATABASE_URL from Secrets Manager, so no local Postgres and no local copy of
# the password is needed. The seed is idempotent (services/api/scripts/seed.ts).
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# USD per hour for env at the defaults (db_multi_az = false, 2 Fargate tasks, 1 NAT, 1 ALB,
# 1 cache node, 3 public IPv4 addresses). Derived from README.md's table / 730 h; keep the two in sync.
HOURLY_COST_USD="${HOURLY_COST_USD:-0.194}"

: "${AWS_PROFILE:=osra-staging}"
: "${AWS_REGION:=eu-north-1}"
export AWS_PROFILE AWS_REGION

command -v terraform >/dev/null 2>&1 || { echo "terraform is not on PATH" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is not on PATH" >&2; exit 1; }

START_FILE="$HERE/.session-start"
if [ -s "$START_FILE" ]; then
  start_epoch=$(cat "$START_FILE")
  echo "Session already started at $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
else
  start_epoch=$(date +%s)
  printf '%s\n' "$start_epoch" >"$START_FILE"
  echo "Session start: $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
fi

echo "==> base (created once; a no-op when nothing changed)"
terraform -chdir="$HERE/base" init -input=false
terraform -chdir="$HERE/base" apply "$@"

echo "==> env (per session)"
terraform -chdir="$HERE/env" init -input=false

# The API exits at boot when the database has no schema, and Terraform waits for a new ECS service
# to stabilise — so a fresh session creates everything except the service, seeds, then starts it.
# A re-run in the same session registers the new task definition first, so the migration runs
# against the new revision before the service is rolled onto it.
service_state=$(terraform -chdir="$HERE/env" state list 2>/dev/null || true)
case "$service_state" in
  *aws_ecs_service.api*)
    echo "    (service exists; registering the task definition before the migration)"
    # -target warns that this is not a complete apply; that is deliberate, the service must not move
    # until the migration below has run.
    terraform -chdir="$HERE/env" apply -target=aws_ecs_task_definition.api "$@"
    ;;
  *)
    echo "    (service deferred until after the seed)"
    terraform -chdir="$HERE/env" apply -var api_service_enabled=false "$@"
    ;;
esac

echo "==> migrate + seed"
cluster=$(terraform -chdir="$HERE/env" output -raw cluster_name)
taskdef=$(terraform -chdir="$HERE/env" output -raw task_definition_arn)
subnets=$(terraform -chdir="$HERE/env" output -raw private_subnet_ids)
sg=$(terraform -chdir="$HERE/env" output -raw api_security_group_id)
log_group=$(terraform -chdir="$HERE/base" output -raw log_group_name)

# Same task definition, one-off command. The image must carry prisma, tsx and scripts/seed.ts
# (services/api/Dockerfile installs devDependencies and copies the service).
task_arn=$(aws ecs run-task \
  --cluster "$cluster" \
  --task-definition "$taskdef" \
  --launch-type FARGATE \
  --started-by osra-up-seed \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"api","command":["sh","scripts/migrate-and-seed.sh"]}]}' \
  --query 'tasks[0].taskArn' --output text)

echo "    seed task: $task_arn"
aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn"

exit_code=$(aws ecs describe-tasks \
  --cluster "$cluster" --tasks "$task_arn" \
  --query 'tasks[0].containers[0].exitCode' --output text)

if [ "$exit_code" != "0" ]; then
  echo "seed task failed (exit $exit_code); last log lines:" >&2
  aws logs tail "$log_group" --since 15m >&2 || true
  exit 1
fi

echo "==> env (service: created on a fresh session, rolled onto the new image otherwise)"
terraform -chdir="$HERE/env" apply "$@"

echo
echo "API URL:        $(terraform -chdir="$HERE/env" output -raw api_url)"
echo "Session start:  $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
echo "Estimated cost: \$$HOURLY_COST_USD/hour for env (base is ~\$2/month and always on)"
echo "                ~\$$(awk -v r="$HOURLY_COST_USD" 'BEGIN { printf "%.2f", r * 8 }') per 8-hour session"
echo
echo "Tear down with: ./infra/terraform/down.sh"
