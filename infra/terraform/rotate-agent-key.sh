#!/usr/bin/env bash
# Rotate the deployer user's access key without a gap (#766 item 7; schedule and owner: osra-security#27).
# Order: create the new key, write it into the credentials file, prove it works, only then delete the old one.
# If anything fails before the new key is proven, a trap deletes the NEW key and restores the credentials
# file, so the old key keeps working and the user is left with exactly one key.
# No Python (on Windows Git Bash `python3` may be the Store stub). The new secret goes from the CLI's answer
# into the credentials file through a private temporary file: never printed, never on a command line.
#
#   bash infra/terraform/rotate-agent-key.sh            # profile osra-staging, user osra-staging-deployer
#   AGENT_PROFILE=x AGENT_USER=y bash infra/terraform/rotate-agent-key.sh
#
# Expect one "osra-agent-key-changed" alarm email for the create and one for the delete.
set -euo pipefail

PROFILE="${AGENT_PROFILE:-osra-staging}"
USER_NAME="${AGENT_USER:-osra-staging-deployer}"
cred_file="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
export AWS_PAGER=""

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
cp "$cred_file" "$tmp/credentials.before"
new_id=""
proven=false

on_exit() {
  status=$?
  if [ "$proven" != true ] && [ -n "$new_id" ]; then
    echo "Rotation failed before the new key was proven: restoring the credentials file and deleting the new key." >&2
    cp "$tmp/credentials.before" "$cred_file"
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

# Rewrite only this profile's two lines in the credentials file; everything else is kept as it was.
# The secret reaches awk through its environment, not its arguments (arguments are visible in the process list).
NEW_SECRET="$new_secret" awk -v p="[$PROFILE]" -v id="$new_id" '
  /^\[/ { inside = ($0 == p) }
  inside && /^[[:space:]]*aws_access_key_id[[:space:]]*=/ { print "aws_access_key_id = " id; next }
  inside && /^[[:space:]]*aws_secret_access_key[[:space:]]*=/ { print "aws_secret_access_key = " ENVIRON["NEW_SECRET"]; next }
  { print }
' "$tmp/credentials.before" >"$tmp/credentials.new"
unset new_secret
grep -q "^aws_access_key_id = $new_id\$" "$tmp/credentials.new" \
  || { echo "profile [$PROFILE] not found in $cred_file" >&2; exit 1; }
cat "$tmp/credentials.new" >"$cred_file"

# A new key can take a few seconds to be accepted everywhere.
for attempt in 1 2 3 4 5 6; do
  if [ "$(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text 2>/dev/null)" != "" ]; then
    proven=true
    break
  fi
  sleep $((attempt * 5))
done
[ "$proven" = true ] || { echo "The new key does not work." >&2; exit 1; }

aws iam delete-access-key --profile "$PROFILE" --user-name "$USER_NAME" --access-key-id "$old_id"
echo "Rotated: ${old_id:0:4}…${old_id: -4} deleted, ${new_id:0:4}…${new_id: -4} active on profile $PROFILE."
