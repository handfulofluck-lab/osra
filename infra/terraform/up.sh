#!/bin/sh
# Bring up a stack: base (idempotent), env, then schema (+ demo seed in staging).
#
#   ./infra/terraform/up.sh                 # staging, from the repo root
#   ./infra/terraform/up.sh -auto-approve   # any extra args go to every apply
#   OSRA_ENV=production ./infra/terraform/up.sh                       # production: PLAN ONLY
#   OSRA_ENV=production OSRA_PROD_APPLY=yes ./infra/terraform/up.sh   # production apply (#714):
#       only with Karim's written go and Ahmed's #637 sign-off for the exact commit.
#
# Why the seed step is a one-off ECS task: the RDS instance is private (no public IP, no route
# from a workstation), so `prisma migrate deploy` must run inside the VPC. The task definition
# already injects DATABASE_URL from Secrets Manager, so no local Postgres and no local copy of
# the password is needed. The seed is idempotent (services/api/scripts/seed.ts).
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

OSRA_ENV="${OSRA_ENV:-staging}"
case "$OSRA_ENV" in
  staging) default_region=eu-north-1 ;;
  production) default_region=eu-central-1 ;;
  *) echo "OSRA_ENV must be staging or production (got '$OSRA_ENV')" >&2; exit 1 ;;
esac

# USD per hour for env at the defaults (db_multi_az = false, 2 Fargate tasks, 1 NAT, 1 ALB,
# 1 cache node, 3 public IPv4 addresses). Derived from README.md's table / 730 h; keep the two in sync.
HOURLY_COST_USD="${HOURLY_COST_USD:-0.194}"

: "${AWS_PROFILE:=osra-staging}"
: "${AWS_REGION:=$default_region}"
export AWS_PROFILE AWS_REGION

command -v terraform >/dev/null 2>&1 || { echo "terraform is not on PATH" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is not on PATH" >&2; exit 1; }

# Each stack's backend comes from a file (#714). -reconfigure because the same directory serves both
# environments; it never copies state between them.
init_stack() {
  stack=$1
  backend_file="$HERE/backend/$OSRA_ENV-$stack.hcl"
  [ -f "$backend_file" ] || { echo "missing $backend_file (copy it from the .example next to it)" >&2; exit 1; }
  terraform -chdir="$HERE/$stack" init -input=false -reconfigure -backend-config="$backend_file"
}

if [ "$OSRA_ENV" = production ]; then
  for stack in base env; do
    # Terraform loads terraform.tfvars by itself, so a staging file in the same directory would quietly
    # fill any value production.tfvars leaves out. Refuse rather than plan against a mixed configuration.
    if [ -f "$HERE/$stack/terraform.tfvars" ]; then
      echo "refusing production: $stack/terraform.tfvars (staging) is present and would be auto-loaded." >&2
      echo "Run production from a separate worktree that has only production.tfvars." >&2
      exit 1
    fi
    [ -f "$HERE/$stack/production.tfvars" ] || { echo "missing $stack/production.tfvars (copy the .example)" >&2; exit 1; }
  done

  echo "==> production base: plan"
  init_stack base
  terraform -chdir="$HERE/base" plan -input=false -var-file=production.tfvars -out=production.tfplan
  echo "==> production env: plan (needs base applied; on a first run it stops here)"
  init_stack env
  terraform -chdir="$HERE/env" plan -input=false -var-file=production.tfvars -out=production.tfplan || {
    echo "    env plan failed. Before base's first apply this is expected: env reads base's state." >&2
    [ "${OSRA_PROD_APPLY:-}" = yes ] || exit 1
  }

  if [ "${OSRA_PROD_APPLY:-}" != yes ]; then
    echo
    echo "Plan only. Saved plans: base/production.tfplan, env/production.tfplan (gitignored)."
    echo "Production applies need Karim's written go and Ahmed's #637 sign-off, then OSRA_PROD_APPLY=yes."
    exit 0
  fi

  echo "==> production base: apply (the plan saved above, nothing else)"
  terraform -chdir="$HERE/base" apply -input=false production.tfplan
  echo "==> production env: plan + apply (service deferred until the schema exists on a first run)"
  service_state=$(terraform -chdir="$HERE/env" state list 2>/dev/null || true)
  case "$service_state" in
    *aws_ecs_service.api*) terraform -chdir="$HERE/env" apply -input=false -var-file=production.tfvars -target=aws_ecs_task_definition.api "$@" ;;
    *) terraform -chdir="$HERE/env" apply -input=false -var-file=production.tfvars -var api_service_enabled=false "$@" ;;
  esac
  # Production migrates only: no demo family in the real database.
  migrate_command='["node_modules/.bin/prisma","migrate","deploy"]'
  env_var_args="-var-file=production.tfvars"
else

# Issue #337: base state is shared in S3, and most of base is `count`-gated on variables that live in a
# GITIGNORED terraform.tfvars. Without that file the counts evaluate to zero, so the apply does not
# "create nothing" — it DESTROYS the certificate, the GitHub OIDC provider and the publish role, and it
# looks exactly like a first-time apply. It happened on 2026-10-23 (DeleteCertificate 12:57:59Z) from a
# fresh clone. Refuse before applying rather than rely on prevent_destroy alone, because a refusal can
# say why.
if [ ! -f "$HERE/base/terraform.tfvars" ]; then
  cat >&2 <<'EOG'
refusing to apply base: infra/terraform/base/terraform.tfvars is missing.

Base state is shared in S3. Without that file the `count`-gated resources evaluate to zero and this
apply would DESTROY the API certificate, the GitHub OIDC provider and the osra-staging-publish role.

Create it (it is gitignored on purpose) from the example and fill in the values:
    cp infra/terraform/base/terraform.tfvars.example infra/terraform/base/terraform.tfvars
    github_repo     = "handfulofluck-lab/osra"
    github_owner_id = "<gh api repos/OWNER/REPO --jq .owner.id>"
    github_repo_id  = "<gh api repos/OWNER/REPO --jq .id>"
    domain_name / hosted_zone_name if the session needs HTTPS.
EOG
  exit 1
fi

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
init_stack base
terraform -chdir="$HERE/base" apply "$@"

# And check what base actually produced before env depends on it. A silent empty output here is how the
# 2026-10-23 session got as far as a publish failure that named GitHub instead of the real cause.
publish_role_arn=$(terraform -chdir="$HERE/base" output -raw publish_role_arn 2>/dev/null || true)
if [ -z "$publish_role_arn" ]; then
  echo "    WARNING: base has no publish_role_arn — an image publish (gh workflow run api-publish.yml)" >&2
  echo "             will fail with an OIDC error that names GitHub. Cause is almost always empty" >&2
  echo "             github_repo/owner_id/repo_id in base/terraform.tfvars. This session can continue;" >&2
  echo "             the publish cannot." >&2
fi

echo "==> env (per session)"
init_stack env

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
migrate_command='["sh","scripts/migrate-and-seed.sh"]'
env_var_args=""
fi

echo "==> migrate$( [ "$OSRA_ENV" = staging ] && echo ' + seed')"
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
  --overrides "{\"containerOverrides\":[{\"name\":\"api\",\"command\":$migrate_command}]}" \
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
# shellcheck disable=SC2086 # env_var_args is empty or one flag without spaces
terraform -chdir="$HERE/env" apply $env_var_args "$@"

echo
echo "API URL:        $(terraform -chdir="$HERE/env" output -raw api_url)"
if [ "$OSRA_ENV" = production ]; then
  exit 0
fi
echo "Session start:  $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
echo "Estimated cost: \$$HOURLY_COST_USD/hour for env (base is ~\$2/month and always on)"
echo "                ~\$$(awk -v r="$HOURLY_COST_USD" 'BEGIN { printf "%.2f", r * 8 }') per 8-hour session"
echo
echo "Tear down with: ./infra/terraform/down.sh"
