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

# Production never falls back to the staging profile (#765, Fable B3): the caller names the profile.
profile_given="${AWS_PROFILE:-}"
# One source of truth for the default's name, because production refuses it by name below (osra#768).
staging_profile=osra-staging
: "${AWS_PROFILE:=$staging_profile}"
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
  # Production runs in two reviewed steps, each "plan to a file, read it, apply exactly that file" (#765):
  #   OSRA_ENV=production AWS_PROFILE=<profile> ./up.sh                       -> saves plans, applies nothing
  #   OSRA_ENV=production AWS_PROFILE=<profile> OSRA_PROD_APPLY=yes ./up.sh   -> applies the saved plans only
  # OSRA_PROD_PHASE=schema (default) defers the service on a first run, or registers only the new task
  # definition on an upgrade, and the apply then snapshots the database and migrates. OSRA_PROD_PHASE=service
  # plans everything else (creating the service, or rolling it onto the new task definition).
  [ -n "$profile_given" ] || { echo "production: set AWS_PROFILE explicitly; it never defaults to the staging profile." >&2; exit 1; }
  # osra#768: the profile must not only be given, it must not be the staging one by name. #765 refuses an
  # unset profile; `OSRA_ENV=production AWS_PROFILE=osra-staging` would still name the credential that
  # belongs to the other environment. A production run names its own credential, or it does not run.
  if [ "$AWS_PROFILE" = "$staging_profile" ]; then
    echo "production: AWS_PROFILE is the staging profile ($staging_profile); name the production profile instead." >&2
    exit 1
  fi
  phase="${OSRA_PROD_PHASE:-schema}"
  case "$phase" in schema|service) ;; *) echo "OSRA_PROD_PHASE must be schema or service" >&2; exit 1 ;; esac

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

  if [ "${OSRA_PROD_APPLY:-}" != yes ]; then
    echo "==> production base: plan -> base/production.tfplan"
    init_stack base
    rc=0
    terraform -chdir="$HERE/base" plan -input=false -detailed-exitcode -var-file=production.tfvars -var environment=production -out=production.tfplan || rc=$?
    case $rc in
      0) rm -f "$HERE/base/production.tfplan"; echo "    base: no changes" ;;
      2) echo; echo "base has changes. Review them, apply with OSRA_PROD_APPLY=yes, then plan again for env"
         echo "(env reads base's outputs, so it is planned only against an applied base)."; exit 0 ;;
      *) exit "$rc" ;;
    esac

    echo "==> production env: plan ($phase) -> env/production.tfplan"
    init_stack env
    env_state=$(terraform -chdir="$HERE/env" state list 2>/dev/null || true)
    if [ "$phase" = schema ]; then
      case "$env_state" in
        *aws_ecs_service.api*) set -- -target=aws_ecs_task_definition.api ;;
        *) set -- -var api_service_enabled=false ;;
      esac
    else
      set --
    fi
    terraform -chdir="$HERE/env" plan -input=false -var-file=production.tfvars -var environment=production "$@" -out=production.tfplan
    printf '%s\n' "$phase" >"$HERE/env/production.tfplan.phase"
    echo
    echo "Saved env/production.tfplan ($phase). Read it (terraform -chdir=infra/terraform/env show production.tfplan),"
    echo "then apply exactly it with OSRA_PROD_APPLY=yes. Every production apply needs Karim's written go."
    exit 0
  fi

  if [ -f "$HERE/base/production.tfplan" ]; then
    echo "==> production base: apply the saved plan"
    init_stack base
    terraform -chdir="$HERE/base" apply -input=false production.tfplan
    rm -f "$HERE/base/production.tfplan"
    echo "Base applied. Plan again (without OSRA_PROD_APPLY) for env."
    exit 0
  fi
  [ -f "$HERE/env/production.tfplan" ] || { echo "no saved plan to apply; run the plan step first." >&2; exit 1; }
  saved_phase=$(cat "$HERE/env/production.tfplan.phase" 2>/dev/null || echo service)

  echo "==> production env: apply the saved plan ($saved_phase)"
  init_stack env
  terraform -chdir="$HERE/env" apply -input=false production.tfplan
  rm -f "$HERE/env/production.tfplan" "$HERE/env/production.tfplan.phase"
  if [ "$saved_phase" = service ]; then
    echo "API URL: $(terraform -chdir="$HERE/env" output -raw api_url)"
    exit 0
  fi

  cluster=$(terraform -chdir="$HERE/env" output -raw cluster_name)
  taskdef=$(terraform -chdir="$HERE/env" output -raw task_definition_arn)
  subnets=$(terraform -chdir="$HERE/env" output -raw private_subnet_ids)
  sg=$(terraform -chdir="$HERE/env" output -raw api_security_group_id)
  log_group=$(terraform -chdir="$HERE/env" output -raw log_group_name)
  db_id=$(terraform -chdir="$HERE/env" output -raw rds_identifier)

  # The CLI calls below must run as the production role, as Terraform does, never as the profile itself.
  role=$(terraform -chdir="$HERE/env" output -raw deploy_role_arn)
  want_account=$(terraform -chdir="$HERE/env" output -raw allowed_account_id)
  creds=$(aws sts assume-role --role-arn "$role" --role-session-name osra-production-migrate \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<EOC
$creds
EOC
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_PROFILE
  got_account=$(aws sts get-caller-identity --query Account --output text)
  if [ "$got_account" != "$want_account" ]; then
    echo "refusing: CLI credentials are for another account than allowed_account_ids." >&2
    exit 1
  fi

  # A manual snapshot before every production migration: point-in-time restore exists, but a named
  # snapshot is the one-step way back from a migration that went wrong.
  snap="$db_id-pre-migrate-$(date -u +%Y%m%d%H%M%S)"
  echo "==> snapshot $snap"
  aws rds create-db-snapshot --db-instance-identifier "$db_id" --db-snapshot-identifier "$snap" >/dev/null
  aws rds wait db-snapshot-available --db-snapshot-identifier "$snap"

  # Production migrates only: no demo family in the real database. The db-admin task (env/db_admin.tf)
  # runs the migration as the master user and grants the osra_api role the API connects as (#766 item 3).
  db_admin_taskdef=$(terraform -chdir="$HERE/env" output -raw db_admin_task_definition_arn 2>/dev/null || true)
  if [ -z "$db_admin_taskdef" ] || [ "$db_admin_taskdef" = null ]; then
    echo "refusing: production has no db-admin task definition (secrets_out_of_band must be true)." >&2
    exit 1
  fi
  migrate_command=""
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
fi

echo "==> migrate$( [ "$OSRA_ENV" = staging ] && echo ' + seed')"
read_env_outputs() {
  cluster=$(terraform -chdir="$HERE/env" output -raw cluster_name)
  taskdef=$(terraform -chdir="$HERE/env" output -raw task_definition_arn)
  subnets=$(terraform -chdir="$HERE/env" output -raw private_subnet_ids)
  sg=$(terraform -chdir="$HERE/env" output -raw api_security_group_id)
  log_group=$(terraform -chdir="$HERE/env" output -raw log_group_name)
}
# Production read them before switching the CLI to the role's credentials (Terraform's backend cannot
# chain from those); staging reads them here.
[ -n "${cluster:-}" ] || read_env_outputs

# Same task definition, one-off command. The image must carry prisma, tsx and scripts/seed.ts
# (services/api/Dockerfile installs devDependencies and copies the service).
if [ -n "${db_admin_taskdef:-}" ]; then
  # Production: the db-admin task carries its own command; no override, so nothing can swap it for another.
  task_arn=$(aws ecs run-task \
    --cluster "$cluster" \
    --task-definition "$db_admin_taskdef" \
    --launch-type FARGATE \
    --started-by osra-up-migrate \
    --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
    --query 'tasks[0].taskArn' --output text)
else
  task_arn=$(aws ecs run-task \
    --cluster "$cluster" \
    --task-definition "$taskdef" \
    --launch-type FARGATE \
    --started-by osra-up-seed \
    --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
    --overrides "{\"containerOverrides\":[{\"name\":\"api\",\"command\":$migrate_command}]}" \
    --query 'tasks[0].taskArn' --output text)
fi

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

if [ "$OSRA_ENV" = production ]; then
  echo
  echo "Migrated. Next: OSRA_PROD_PHASE=service plan, review, then apply it (creates or rolls the service)."
  exit 0
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
