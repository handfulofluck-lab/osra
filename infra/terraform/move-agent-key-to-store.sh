#!/usr/bin/env bash
# One-time move of the deployer user's key out of the plain-text credentials file into the Windows DPAPI
# store (Ahmed control 4, #637 comment 6881460052; runbook osra-security#27). Run on Karim's PC, in Git Bash,
# as Karim's Windows user. Afterwards the profile reads its key through agent-credential.ps1, so the AWS CLI,
# Terraform, the AWS MCP server and Kimi's tools keep working unchanged; the key no longer sits in a text file.
#
#   bash infra/terraform/move-agent-key-to-store.sh            # profile osra-staging
#   AGENT_PROFILE=x bash infra/terraform/move-agent-key-to-store.sh
#
# Order: write the store, prove the store alone works (a scratch config with only credential_process), then
# switch the real profile and remove the two key lines from the credentials file. Backups of both files stay
# in a private folder until the end; on any failure both files are restored and nothing has changed.
set -euo pipefail

PROFILE="${AGENT_PROFILE:-osra-staging}"
cred_file="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
config_file="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/agent-store.sh"
export AWS_PAGER=""

# The profile runs an installed copy of the helper ($AGENT_HELPER, beside the store), never the file in this
# checkout, and names it without quotes: Terraform's AWS SDK (Go) passes quotes to PowerShell literally and
# fails with "Illegal characters in path" (15 Nov production plan; the AWS CLI accepted either form).
helper_before=""
[ -f "$AGENT_HELPER" ] && helper_before=$(mktemp) && cp "$AGENT_HELPER" "$helper_before"
process=$(agent_helper_install "$here/agent-credential.ps1")

# A profile already moved (no key lines left, a credential_process set): only repoint it at the installed
# copy. Recognised by shape, not by the helper's file name, so a profile edited by hand to any spelling of
# the old path (long, 8.3 short) is brought over too (#821 Fable B2). The checks below prove the result.
if [ -z "$(aws configure get aws_access_key_id --profile "$PROFILE" 2>/dev/null)" ] \
   && [ -n "$(aws configure get credential_process --profile "$PROFILE" 2>/dev/null)" ]; then
  previous=$(aws configure get credential_process --profile "$PROFILE")
  aws configure set credential_process "$process" --profile "$PROFILE"
  if [ "$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)" = "" ] \
     || [ "$(agent_store_id)" = "" ]; then
    aws configure set credential_process "$previous" --profile "$PROFILE"
    if [ -n "$helper_before" ]; then cp "$helper_before" "$AGENT_HELPER"; fi
    echo "repoint failed: profile $PROFILE restored to its previous credential_process" >&2
    exit 1
  fi
  if [ -n "$helper_before" ]; then rm -f "$helper_before"; fi
  echo "Repointed: profile $PROFILE now runs $(cygpath -w "$AGENT_HELPER"); the key stays in the store."
  exit 0
fi

id=$(aws configure get aws_access_key_id --profile "$PROFILE")
secret=$(aws configure get aws_secret_access_key --profile "$PROFILE")
[ -n "$id" ] && [ -n "$secret" ] || { echo "profile $PROFILE has no key in $cred_file (already moved?)" >&2; exit 1; }
want=$(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text)

umask 077
tmp=$(mktemp -d)
cp "$cred_file" "$tmp/credentials.before"
cp "$config_file" "$tmp/config.before"
[ -f "$AGENT_STORE" ] && cp "$AGENT_STORE" "$tmp/store.before"
done=false
on_exit() {
  status=$?
  if [ "$done" != true ]; then
    echo "Move failed: restoring the credentials and config files." >&2
    cp "$tmp/credentials.before" "$cred_file"
    cp "$tmp/config.before" "$config_file"
    if [ -f "$tmp/store.before" ]; then cp "$tmp/store.before" "$AGENT_STORE"; else rm -f "$AGENT_STORE"; fi
    if [ -n "$helper_before" ]; then cp "$helper_before" "$AGENT_HELPER"; else rm -f "$AGENT_HELPER"; fi
  fi
  rm -rf "$tmp"
  if [ -n "$helper_before" ]; then rm -f "$helper_before"; fi
  exit "$status"
}
trap on_exit EXIT INT TERM

agent_store_write "$id" "$secret"
unset secret

# Prove the store alone, with no credentials file in reach.
printf '[profile probe]\ncredential_process = %s\n' "$process" >"$tmp/probe-config"
got=$(AWS_CONFIG_FILE="$tmp/probe-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null \
  aws sts get-caller-identity --profile probe --query Arn --output text)
[ "$got" = "$want" ] || { echo "the store does not give the same identity" >&2; exit 1; }

# Switch the profile: credential_process in config, key lines out of the credentials file.
aws configure set credential_process "$process" --profile "$PROFILE"
awk -v p="[$PROFILE]" '
  /^\[/ { inside = ($0 == p) }
  inside && /^[[:space:]]*aws_(access_key_id|secret_access_key|session_token)[[:space:]]*=/ { next }
  { print }
' "$tmp/credentials.before" >"$tmp/credentials.new"
cat "$tmp/credentials.new" >"$cred_file"

got=$(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text)
[ "$got" = "$want" ] || { echo "the profile does not work after the switch" >&2; exit 1; }
aws configure get credential_process --profile "$PROFILE" | grep -q 'osra-agent-credential\.ps1' \
  || { echo "the profile does not run the installed helper" >&2; exit 1; }
[ "$(agent_store_id)" = "$id" ] || { echo "the installed helper does not read the stored key" >&2; exit 1; }
if grep -q "${id}" "$cred_file"; then echo "the key id is still in $cred_file" >&2; exit 1; fi
done=true
echo "Moved: profile $PROFILE now reads its key from the DPAPI store ($AGENT_STORE); $cred_file no longer holds it."
