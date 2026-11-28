#!/usr/bin/env bash
# The throw-away load-test stack (loadtest/README.md). Staging AWS account, eu-north-1, its own base and env state.
# Never staging's stack, never production.
#
#   ./infra/terraform/loadtest.sh up   -auto-approve        # base + env, migrate, start the API (prints the URL)
#   ./infra/terraform/loadtest.sh seed 10000                # synthetic families (idempotent; can be re-run)
#   ./infra/terraform/loadtest.sh run  steady 10000 3 <ref> # SCENARIO FAMILIES GENERATORS [git ref of the k6 scripts]
#   ./infra/terraform/loadtest.sh down -auto-approve        # env, then the load-test base: nothing is left
#
# Run it from a SEPARATE worktree that has only base/loadtest.tfvars and env/loadtest.tfvars: Terraform auto-loads
# terraform.tfvars, so a staging file next to them would quietly fill values (same rule as production).
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGING_ACCOUNT=222207908538
: "${AWS_PROFILE:=osra-staging}"
: "${AWS_REGION:=eu-north-1}"
export AWS_PROFILE AWS_REGION

cmd=${1:-}
[ -n "$cmd" ] || { sed -n '2,12p' "$0"; exit 1; }
shift

command -v terraform >/dev/null 2>&1 || { echo "terraform is not on PATH" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is not on PATH" >&2; exit 1; }

# Saturday 28 Nov 2026 family test on staging ends ~17:30 UAE (13:30 UTC): nothing before it (Karim's rule).
# Compared as YYYYMMDDHHMM digits, because macOS/BSD `date` has no GNU `-d` (Codex's review of #1281). `down` is
# never blocked by the clock: tearing down must always be possible.
NOT_BEFORE_UTC=202611281330
if [ "$cmd" != down ] && [ "$(date -u +%Y%m%d%H%M)" -lt "$NOT_BEFORE_UTC" ]; then
  echo "refusing: no load-test stack before the Saturday family test ends (Sat 28 Nov 17:30 UAE)." >&2
  exit 1
fi

account=$(aws sts get-caller-identity --query Account --output text)
[ "$account" = "$STAGING_ACCOUNT" ] || { echo "refusing: credentials are for account $account, not the staging account." >&2; exit 1; }

for stack in base env; do
  if [ -f "$HERE/$stack/terraform.tfvars" ]; then
    echo "refusing: $stack/terraform.tfvars (staging) is present and would be auto-loaded. Use a separate worktree." >&2
    exit 1
  fi
  [ -f "$HERE/$stack/loadtest.tfvars" ] || { echo "missing $stack/loadtest.tfvars (copy the .example)" >&2; exit 1; }
  grep -q '^environment *= *"loadtest"' "$HERE/$stack/loadtest.tfvars" || { echo "refusing: $stack/loadtest.tfvars must say environment = \"loadtest\"." >&2; exit 1; }
done
# The env must read the load-test base, never staging's (Terraform's loadtest_guard refuses it too).
grep -q '^base_state_key *= *"loadtest/base/terraform.tfstate"' "$HERE/env/loadtest.tfvars" \
  || { echo "refusing: env/loadtest.tfvars must say base_state_key = \"loadtest/base/terraform.tfstate\"." >&2; exit 1; }

init_stack() { terraform -chdir="$HERE/$1" init -input=false -reconfigure -backend-config="$HERE/backend/loadtest-$1.hcl" >/dev/null; }
out() { terraform -chdir="$HERE/env" output -raw "$1"; }

run_api_task() { # $1 = shell command inside the API image, $2 = extra env JSON entries
  cluster=$(out cluster_name); taskdef=$(out task_definition_arn)
  subnets=$(out private_subnet_ids); sg=$(out api_security_group_id)
  overrides=$(printf '{"containerOverrides":[{"name":"api","command":["sh","-c","%s"],"environment":[%s]}]}' "$1" "$2")
  arn=$(aws ecs run-task --cluster "$cluster" --task-definition "$taskdef" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
    --overrides "$overrides" --query 'tasks[0].taskArn' --output text)
  echo "    task $arn"
  aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$arn"
  code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$arn" --query 'tasks[0].containers[?name==`api`].exitCode | [0]' --output text)
  [ "$code" = 0 ] || { echo "task exited $code; logs: $(out log_group_name), stream prefix api" >&2; exit 1; }
}

case "$cmd" in
  up)
    printf '%s\n' "$(date -u +%s)" >"$HERE/.loadtest-start"
    echo "==> load-test base"
    init_stack base
    terraform -chdir="$HERE/base" apply -input=false -var-file=loadtest.tfvars "$@"
    echo "==> load-test env (no API service yet)"
    init_stack env
    terraform -chdir="$HERE/env" apply -input=false -var-file=loadtest.tfvars -var api_service_enabled=false "$@"
    echo "==> migrate"
    run_api_task "node_modules/.bin/prisma migrate deploy" ""
    echo "==> load-test env (API service)"
    terraform -chdir="$HERE/env" apply -input=false -var-file=loadtest.tfvars "$@"
    echo "Load-test API: $(out api_url)"
    ;;
  seed)
    families=${1:?seed FAMILIES}
    echo "==> seed $families synthetic families"
    init_stack env
    run_api_task "node_modules/.bin/tsx scripts/loadtest-seed.ts" \
      "{\"name\":\"LOADTEST_SEED_CONFIRM\",\"value\":\"synthetic-only\"},{\"name\":\"LOADTEST_FAMILIES\",\"value\":\"$families\"},{\"name\":\"LOADTEST_HISTORY_DAYS\",\"value\":\"${LOADTEST_HISTORY_DAYS:-1}\"}"
    ;;
  run)
    scenario=${1:?run SCENARIO FAMILIES GENERATORS [REF]}; families=${2:?FAMILIES}; generators=${3:-1}; ref=${4:-main}
    init_stack env
    cluster=$(out cluster_name); taskdef=$(out loadtest_k6_task_definition_arn)
    subnets=$(out private_subnet_ids); sg=$(out loadtest_k6_security_group_id)
    [ -n "$taskdef" ] || { echo "no k6 task definition: is loadtest_mode = true in env/loadtest.tfvars?" >&2; exit 1; }
    share=$(awk -v n="$generators" 'BEGIN { printf "%.6f", 1 / n }')
    script="https://raw.githubusercontent.com/handfulofluck-lab/osra/$ref/loadtest/k6/family-mix.js"
    extra=""
    for kv in ${K6_EXTRA:-}; do extra="$extra,\"-e\",\"$kv\""; done
    overrides=$(printf '{"containerOverrides":[{"name":"k6","command":["run","--no-color","-e","SCENARIO=%s","-e","FAMILIES=%s","-e","SHARE=%s"%s,"%s"]}]}' "$scenario" "$families" "$share" "$extra" "$script")
    echo "==> $scenario, $families families, $generators generator(s), scripts at $ref"
    aws ecs run-task --cluster "$cluster" --task-definition "$taskdef" --launch-type FARGATE --count "$generators" \
      --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
      --overrides "$overrides" --query 'tasks[].taskArn' --output text
    echo "Results: CloudWatch log group $(out log_group_name), stream prefix k6 (one stream per generator)."
    ;;
  down)
    echo "==> load-test env destroy"
    init_stack env
    terraform -chdir="$HERE/env" destroy -input=false -var-file=loadtest.tfvars "$@"
    echo "==> load-test base destroy (throw-away; staging's base is a different state and is not touched)"
    init_stack base
    terraform -chdir="$HERE/base" destroy -input=false -var-file=loadtest.tfvars "$@"
    if [ -s "$HERE/.loadtest-start" ]; then
      start=$(cat "$HERE/.loadtest-start"); hours=$(awk -v s="$(( $(date -u +%s) - start ))" 'BEGIN { printf "%.2f", s / 3600 }')
      echo "Load-test stack lived ${hours} h. Check the real spend in Cost Explorer (tag Environment=loadtest) the next day."
      rm -f "$HERE/.loadtest-start"
    fi
    ;;
  *) echo "unknown command '$cmd' (up | seed | run | down)" >&2; exit 1 ;;
esac
