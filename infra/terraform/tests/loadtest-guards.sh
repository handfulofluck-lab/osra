#!/usr/bin/env bash
# CI check for loadtest.sh's guards (Codex's review of #1281). aws, terraform and date are stubs on PATH: no AWS
# call, no Terraform run. The fake `date` behaves like macOS/BSD date and REJECTS GNU `-d`, so a GNU-only date
# call in the script fails here as it did on the Mac.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/bin"
cat >"$root/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE/calls"
case "$1 $2" in
  "sts get-caller-identity") echo "$FAKE_ACCOUNT" ;;
  "ecs describe-tasks") echo 0 ;;
  *) echo "arn:aws:ecs:eu-north-1:0:task/fake" ;;
esac
SH
cat >"$root/bin/terraform" <<'SH'
#!/usr/bin/env bash
echo "terraform $*" >>"$FAKE/calls"
case " $* " in *" output "*) echo "fake-output" ;; esac
exit 0
SH
cat >"$root/bin/date" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-d" ] && { echo "date: illegal option -- d" >&2; exit 1; }; done
case "$*" in
  *%Y%m%d%H%M*) echo "$FAKE_NOW" ;;
  *%s*) echo 1800000000 ;;
  *) /bin/date "$@" ;;
esac
SH
chmod +x "$root/bin/"*

fail=0
# name want_rc command now account [setup]
run() {
  local name=$1 want=$2 cmd=$3 now=$4 account=$5 setup=${6:-} rc=0 out
  local d="$root/$name"
  mkdir -p "$d/tf/base" "$d/tf/env" "$d/tf/backend"
  cp "$here/loadtest.sh" "$d/tf/"
  cp "$here/backend/loadtest-base.hcl" "$here/backend/loadtest-env.hcl" "$d/tf/backend/"
  printf 'environment = "loadtest"\n' >"$d/tf/base/loadtest.tfvars"
  printf 'environment = "loadtest"\nbase_state_key = "loadtest/base/terraform.tfstate"\n' >"$d/tf/env/loadtest.tfvars"
  : >"$d/calls"
  [ -n "$setup" ] && (cd "$d/tf" && eval "$setup")
  LAST_CALLS="$d/calls"; LAST_OUT=""
  out=$(FAKE="$d" FAKE_NOW="$now" FAKE_ACCOUNT="$account" PATH="$root/bin:$PATH" bash "$d/tf/loadtest.sh" $cmd 2>&1) || rc=$?
  LAST_OUT=$out
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: rc $rc, want $want"; echo "$out" | sed 's/^/    /'; fail=1; return
  fi
  if grep -q 'staging-\(base\|env\)\.hcl' "$d/calls"; then echo "FAIL $name: touched a staging backend"; fail=1; return; fi
  echo "ok   $name"
}

STAGING=222207908538
run before_window_up_refused   1 "up -auto-approve"   202611281200 $STAGING
grep -q terraform "$LAST_CALLS" && { echo "FAIL before_window_up_refused: terraform ran"; fail=1; }
echo "$LAST_OUT" | grep -q "before the Saturday family test" || { echo "FAIL before_window_up_refused: wrong reason"; fail=1; }

run before_window_down_allowed 0 "down -auto-approve" 202611281200 $STAGING
grep -q "terraform -chdir=.*/env destroy" "$LAST_CALLS" || { echo "FAIL before_window_down_allowed: no env destroy"; fail=1; }

run wrong_account_refused      1 "up -auto-approve"   202611290600 111111111111
run staging_tfvars_refused     1 "up -auto-approve"   202611290600 $STAGING 'touch base/terraform.tfvars'
run staging_base_key_refused   1 "up -auto-approve"   202611290600 $STAGING 'printf "environment = \"loadtest\"\n" >env/loadtest.tfvars'
run not_loadtest_env_refused   1 "up -auto-approve"   202611290600 $STAGING 'printf "environment = \"staging\"\n" >base/loadtest.tfvars'

run after_window_up_runs       0 "up -auto-approve"   202611290600 $STAGING
grep -q "backend-config=.*loadtest-base.hcl" "$LAST_CALLS" && grep -q "backend-config=.*loadtest-env.hcl" "$LAST_CALLS" \
  || { echo "FAIL after_window_up_runs: did not use both load-test backends"; fail=1; }

[ "$fail" = 0 ] && echo "loadtest guards: ok"
exit "$fail"
