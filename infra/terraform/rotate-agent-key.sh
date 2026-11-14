#!/usr/bin/env bash
# Rotate the agents' permanent access key without a gap (#766 item 7). Run on Karim's PC, where the key
# lives in ~/.aws/credentials under the profile named below. Order: create the new key, write it to the
# profile, prove it works, only then delete the old one. If any step fails, the old key is untouched and
# still works. The new secret goes straight from the AWS response into the credentials file: it is never
# printed, logged or written anywhere else.
#
#   bash infra/terraform/rotate-agent-key.sh            # profile osra-staging, user osra-staging-deployer
#   AGENT_PROFILE=x AGENT_USER=y bash infra/terraform/rotate-agent-key.sh
#
# Expect one "osra-agent-key-changed" alarm email for the create and one for the delete.
set -euo pipefail

PROFILE="${AGENT_PROFILE:-osra-staging}"
USER_NAME="${AGENT_USER:-osra-staging-deployer}"

old_ids=$(aws iam list-access-keys --profile "$PROFILE" --user-name "$USER_NAME" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text)
count=$(wc -w <<<"$old_ids")
if [ "$count" -ne 1 ]; then
  echo "Expected exactly one key on $USER_NAME, found $count. Delete the stray one by hand first." >&2
  exit 1
fi
old_id="$old_ids"

new_json=$(aws iam create-access-key --profile "$PROFILE" --user-name "$USER_NAME" --output json)
new_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$new_json")
new_secret=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$new_json")
unset new_json

cred_file="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
cp "$cred_file" "$cred_file.before-rotation"
aws configure set aws_access_key_id "$new_id" --profile "$PROFILE"
aws configure set aws_secret_access_key "$new_secret" --profile "$PROFILE"
unset new_secret

# A new key can take a few seconds to be accepted everywhere.
for attempt in 1 2 3 4 5 6; do
  if aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep $((attempt * 5))
done

if [ "${ok:-}" != 1 ]; then
  echo "The new key does not work yet. Restoring the old credentials file; the old key is untouched." >&2
  cp "$cred_file.before-rotation" "$cred_file"
  exit 1
fi

aws iam delete-access-key --profile "$PROFILE" --user-name "$USER_NAME" --access-key-id "$old_id"
rm -f "$cred_file.before-rotation"
echo "Rotated: ${old_id:0:4}…${old_id: -4} deleted, ${new_id:0:4}…${new_id: -4} active on profile $PROFILE."
