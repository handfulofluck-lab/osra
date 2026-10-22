#!/bin/sh
# Destroy only the per-session stack. base (ECR, secrets, certificate, IAM, logs) is never touched.
#
#   ./infra/terraform/down.sh
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Must match up.sh; both derive from README.md's table / 730 h.
HOURLY_COST_USD="${HOURLY_COST_USD:-0.194}"

: "${AWS_PROFILE:=osra-staging}"
: "${AWS_REGION:=me-central-1}"
export AWS_PROFILE AWS_REGION

command -v terraform >/dev/null 2>&1 || { echo "terraform is not on PATH" >&2; exit 1; }

terraform -chdir="$HERE/env" init -input=false >/dev/null

# Refuse rather than report a successful teardown of something that was never created. `state
# list` reads the backend without evaluating variables, so it cannot be confused by a missing
# api_image (which `terraform output` would prompt for and die on).
if [ -z "$(terraform -chdir="$HERE/env" state list 2>/dev/null)" ]; then
  echo "env has never been applied (staging/env/terraform.tfstate holds no resources); nothing to destroy." >&2
  exit 1
fi

echo "==> env destroy (base is left alone)"
terraform -chdir="$HERE/env" destroy "$@"

START_FILE="$HERE/.session-start"
if [ -s "$START_FILE" ]; then
  start_epoch=$(cat "$START_FILE")
  end_epoch=$(date +%s)
  seconds=$((end_epoch - start_epoch))
  hours=$(awk -v s="$seconds" 'BEGIN { printf "%.2f", s / 3600 }')
  spend=$(awk -v s="$seconds" -v r="$HOURLY_COST_USD" 'BEGIN { printf "%.2f", (s / 3600) * r }')
  echo
  echo "Session start:     $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Session end:       $(date -d "@$end_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Elapsed:           ${hours} h"
  echo "Estimated spend:   \$$spend (env at \$$HOURLY_COST_USD/hour)"
  rm -f "$START_FILE"
else
  echo
  echo "No session start file found; elapsed time and spend are unavailable." >&2
fi
