#!/usr/bin/env bash
# Rotate the deployer user's access key without a gap (#766 item 7; schedule and owner: osra-security#27).
# Order: create the new key, write it into the credentials file, prove it works, only then delete the old one.
# If anything fails before the new key is proven, a trap deletes the NEW key and restores the credentials
# file, so the old key keeps working and the user is left with exactly one key.
# No Python (on Windows Git Bash `python3` may be the Store stub). The new secret goes from the CLI's answer
# into the key store through a private temporary file: never printed, never on a command line.
# Key store: if the profile uses agent-credential.ps1 (move-agent-key-to-store.sh, Ahmed control 4) the key is
# written to the DPAPI store; otherwise to the credentials file, the pre-migration layout.
# --check prints which mode the profile is in and exits before any key is created.
#
#   bash infra/terraform/rotate-agent-key.sh            # profile osra-staging, user osra-staging-deployer
#   AGENT_PROFILE=x AGENT_USER=y bash infra/terraform/rotate-agent-key.sh
#
# Expect one "osra-agent-key-changed" alarm email for the create and one for the delete.
set -euo pipefail

# Mac phase1 has no rotation. Refuse before reading storage or invoking any credential/AWS helper.
# The existing Windows path below remains unchanged.
if [ "${1:-}" = "--mac" ]; then
  echo "Mac rotation is disabled in phase 1; renewal requires the owner's approved MFA key-creation step." >&2
  exit 1
fi

PROFILE="${AGENT_PROFILE:-osra-staging}"
USER_NAME="${AGENT_USER:-osra-staging-deployer}"
cred_file="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
config_file="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
export AWS_PAGER=""
. "$(dirname "$0")/lib/agent-store.sh"
# Store mode when the profile has a credential_process and no key lines, whatever the helper's path is
# spelled as (#821 Fable B2). Store mode reads the key back through the installed helper, so stop before any
# key is created if that helper is not installed yet (Fable B3).
if [ -z "$(aws configure get aws_access_key_id --profile "$PROFILE" 2>/dev/null)" ] \
   && [ -n "$(aws configure get credential_process --profile "$PROFILE" 2>/dev/null)" ]; then
  mode=store; key_file="$AGENT_STORE"
  if [ ! -f "$AGENT_HELPER" ] || ! aws configure get credential_process --profile "$PROFILE" | grep -qi "$AGENT_HELPER_PATTERN"; then
    echo "Profile $PROFILE does not run the installed helper $AGENT_HELPER yet: run move-agent-key-to-store.sh first to install it and repoint the profile. No key was created." >&2
    exit 1
  fi
else
  mode=file; key_file="$cred_file"
fi

if [ "${1:-}" = "--check" ]; then
  # Prints the mode and stops before anything is created (Fable on #821).
  echo "Check: profile $PROFILE is in $mode mode ($key_file); no key was created."
  exit 0
fi

old_ids=$(aws iam list-access-keys --profile "$PROFILE" --user-name "$USER_NAME" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text)
count=$(wc -w <<<"$old_ids")
if [ "$count" -ne 1 ]; then
  echo "Expected exactly one key on $USER_NAME, found $count. Delete the stray one by hand first." >&2
  exit 1
fi
old_id="$old_ids"

umask 077
tmp=$(mktemp -d)
cp "$key_file" "$tmp/key.before"
new_id=""
proven=false

on_exit() {
  status=$?
  if [ "$proven" != true ] && [ -n "$new_id" ]; then
    echo "Rotation failed before the new key was proven: restoring the key $mode and deleting the new key." >&2
    cp "$tmp/key.before" "$key_file"
    aws iam delete-access-key --profile "$PROFILE" --user-name "$USER_NAME" --access-key-id "$new_id" >/dev/null 2>&1 \
      || echo "WARNING: could not delete the new key ${new_id:0:4}…${new_id: -4}; delete it by hand." >&2
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap on_exit EXIT INT TERM

# Id and secret come back as one tab-separated line, straight into a private file.
aws iam create-access-key --profile "$PROFILE" --user-name "$USER_NAME" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text >"$tmp/new"
read -r new_id new_secret <"$tmp/new"
rm -f "$tmp/new"
[ -n "$new_id" ] && [ -n "${new_secret:-}" ] || { echo "create-access-key returned nothing usable" >&2; exit 1; }

if [ "$mode" = store ]; then
  agent_store_write "$new_id" "$new_secret" || { echo "could not write the key store $AGENT_STORE" >&2; exit 1; }
  unset new_secret
  # A write that silently failed would leave the OLD key in the store; the proof below would then pass with it
  # and the old key would be deleted. So the store must hand back the new id before anything is proven.
  [ "$(agent_store_id 2>/dev/null)" = "$new_id" ] \
    || { echo "the key store does not hold the new key after writing it" >&2; exit 1; }
else
  # Rewrite only this profile's two lines in the credentials file; everything else is kept as it was.
  # The secret reaches awk through its environment, not its arguments (arguments are visible in the process list).
  NEW_SECRET="$new_secret" awk -v p="[$PROFILE]" -v id="$new_id" '
    /^\[/ { inside = ($0 == p) }
    inside && /^[[:space:]]*aws_access_key_id[[:space:]]*=/ { print "aws_access_key_id = " id; next }
    inside && /^[[:space:]]*aws_secret_access_key[[:space:]]*=/ { print "aws_secret_access_key = " ENVIRON["NEW_SECRET"]; next }
    { print }
  ' "$tmp/key.before" >"$tmp/credentials.new"
  unset new_secret
  grep -q "^aws_access_key_id = $new_id\$" "$tmp/credentials.new" \
    || { echo "profile [$PROFILE] not found in $cred_file" >&2; exit 1; }
  cat "$tmp/credentials.new" >"$cred_file"
fi

# A new key can take a few seconds to be accepted everywhere.
for attempt in 1 2 3 4 5 6; do
  if [ "$(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text 2>/dev/null)" != "" ]; then
    proven=true
    break
  fi
  sleep $((attempt * 5))
done
[ "$proven" = true ] || { echo "The new key does not work." >&2; exit 1; }

if ! aws iam delete-access-key --profile "$PROFILE" --user-name "$USER_NAME" --access-key-id "$old_id"; then
  echo "THE NEW KEY WORKS AND IS SAVED, BUT THE OLD KEY ${old_id:0:4}…${old_id: -4} WAS NOT DELETED." >&2
  echo "The user now has two working keys and the next run will refuse to start. Delete the old one with:" >&2
  echo "  aws iam delete-access-key --profile $PROFILE --user-name $USER_NAME --access-key-id <the id ending ${old_id: -4}>" >&2
  echo "  (aws iam list-access-keys --profile $PROFILE --user-name $USER_NAME shows both ids)" >&2
  exit 1
fi
echo "Rotated: ${old_id:0:4}…${old_id: -4} deleted, ${new_id:0:4}…${new_id: -4} active on profile $PROFILE."
