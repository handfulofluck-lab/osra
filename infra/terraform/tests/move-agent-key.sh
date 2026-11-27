#!/usr/bin/env bash
# CI check for move-agent-key-to-store.sh's repoint path (#821, Kimi's review): a repoint must keep the same
# identity, or put the previous credential_process back and fail. aws, powershell.exe and cygpath are stubs
# on PATH: no AWS call, no Windows, no real key. Mutant this kills: replacing the identity check at the
# repoint with `if false; then` turns T2 and T3 green-with-wrong-profile; here they go red.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/bin"
# Fake aws: the profile's credential_process lives in $FAKE/cp. The identity it gives depends on which helper
# the line names: the installed copy gives $FAKE_NEW_ARN, anything else gives $FAKE_OLD_ARN.
cat >"$root/bin/aws" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "configure get")
    case "$3" in
      aws_access_key_id) exit 1 ;;
      credential_process) cat "$FAKE/cp" ;;
    esac ;;
  "configure set") printf '%s' "$4" >"$FAKE/cp" ;;
  "sts get-caller-identity")
    if grep -q 'osra-agent-credential\.ps1' "$FAKE/cp"; then echo "$FAKE_NEW_ARN"; else echo "$FAKE_OLD_ARN"; fi ;;
  *) echo "unexpected aws call: $*" >&2; exit 2 ;;
esac
SH
# Fake powershell.exe: agent_store_id is the only caller on this path; it prints the stored key id.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FAKE_STORE_ID"\n' >"$root/bin/powershell.exe"
# Fake cygpath: -w and -m give the path back unchanged.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$2"\n' >"$root/bin/cygpath"
chmod +x "$root/bin/"*

run() { # name want_rc old_arn new_arn store_id
  local name=$1 want=$2 fake="$root/$1" rc=0 out
  mkdir -p "$fake/home/.aws"
  printf 'powershell.exe -File C:\\old\\agent-credential.ps1' >"$fake/cp"
  out=$(HOME="$fake/home" FAKE="$fake" FAKE_OLD_ARN=$3 FAKE_NEW_ARN=$4 FAKE_STORE_ID=$5 PATH="$root/bin:$PATH" \
    AGENT_STORE="$fake/home/.aws/osra-agent.dpapi" AGENT_HELPER="$fake/home/.aws/osra-agent-credential.ps1" \
    bash "$here/move-agent-key-to-store.sh" 2>&1) || rc=$?
  [ "$rc" -eq "$want" ] || { echo "$name: exit $rc, wanted $want: $out" >&2; exit 1; }
  printf '%s' "$out"
}

# T1: same identity, store readable: repointed at the installed helper.
run t1 0 "arn:aws:iam::111111111111:user/A" "arn:aws:iam::111111111111:user/A" AKIAFAKE >/dev/null
grep -q 'osra-agent-credential\.ps1' "$root/t1/cp" || { echo "t1: profile not repointed" >&2; exit 1; }

# T2: the new line gives another identity: fail, previous credential_process restored.
run t2 1 "arn:aws:iam::111111111111:user/A" "arn:aws:iam::111111111111:user/B" AKIAFAKE >/dev/null
[ "$(cat "$root/t2/cp")" = 'powershell.exe -File C:\old\agent-credential.ps1' ] \
  || { echo "t2: identity changed but the swapped credential_process stayed" >&2; exit 1; }

# T3: same identity but the installed helper reads no key: fail, previous line restored.
run t3 1 "arn:aws:iam::111111111111:user/A" "arn:aws:iam::111111111111:user/A" "" >/dev/null
[ "$(cat "$root/t3/cp")" = 'powershell.exe -File C:\old\agent-credential.ps1' ] \
  || { echo "t3: empty store but the swapped credential_process stayed" >&2; exit 1; }

# T4: the profile gives no identity before the repoint: refuse, nothing changed.
run t4 1 "" "" AKIAFAKE >/dev/null
[ "$(cat "$root/t4/cp")" = 'powershell.exe -File C:\old\agent-credential.ps1' ] \
  || { echo "t4: changed a profile that had no identity" >&2; exit 1; }

echo "move-agent-key repoint: ok"
