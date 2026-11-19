# Optional attribution for direct IAM-agent callers. The entry role's trust, not this input, verifies
# that the value is the caller's own username. Empty preserves the owner's Identity Center path.
agent_assume_production_role() {
  local source_identity="${OSRA_AGENT_SOURCE_IDENTITY:-}"
  local args=(sts assume-role --role-arn "$1" --role-session-name "$2"
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
  if [ -n "$source_identity" ]; then
    if [[ ! "$source_identity" =~ ^[A-Za-z0-9_+=,.@-]{2,64}$ ]] || [[ "$source_identity" = aws:* ]]; then
      echo "refusing: invalid agent SourceIdentity." >&2
      return 1
    fi
    args+=(--source-identity "$source_identity")
  fi
  aws "${args[@]}"
}
