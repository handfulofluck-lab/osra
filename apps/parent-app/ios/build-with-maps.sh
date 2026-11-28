#!/usr/bin/env bash
set +x
set -euo pipefail

maps_key=${MAPS_IOS_API_KEY:-}
unset MAPS_IOS_API_KEY
if [[ -z "$maps_key" ]]; then
  exec flutter build "$@"
fi

case "$maps_key" in
  *[!A-Za-z0-9_-]*)
    echo "Invalid iOS Maps key format" >&2
    exit 1
    ;;
esac

for arg in "$@"; do
  case "$arg" in
    MAPS_API_KEY=*|--dart-define=MAPS_API_KEY=*|--verbose|-v)
      echo "Use the iOS Maps build secret and non-verbose Flutter output" >&2
      exit 1
      ;;
  esac
done

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/osra-ios-maps.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

# Preserve any additional settings supplied by a signed-build caller.
if [[ -n "${XCODE_XCCONFIG_FILE:-}" ]]; then
  existing=$XCODE_XCCONFIG_FILE
  if [[ "$existing" != /* ]]; then
    existing="$PWD/$existing"
  fi
  printf '#include "%s"\n' "$existing" > "$work/maps.xcconfig"
fi
printf 'MAPS_API_KEY = %s\n' "$maps_key" >> "$work/maps.xcconfig"
printf '{"MAPS_API_KEY":"%s"}\n' "$maps_key" > "$work/maps.json"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  # Actions masks the secret value. Flutter also writes the encoded define.
  printf '::add-mask::%s\n' "$(printf 'MAPS_API_KEY=%s' "$maps_key" | base64 | tr -d '\r\n')"
fi
unset maps_key

XCODE_XCCONFIG_FILE="$work/maps.xcconfig" \
  flutter build "$@" --dart-define-from-file="$work/maps.json"
