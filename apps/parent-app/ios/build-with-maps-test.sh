#!/usr/bin/env bash
set -euo pipefail

work=$(mktemp -d "${TMPDIR:-/tmp}/osra-ios-maps-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/tmp"
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp"
build_script="$(dirname "$0")/build-with-maps.sh"
printf 'CODE_SIGN_STYLE = Manual\n' > "$work/signing.xcconfig"
export EXPECTED_XCCONFIG="$work/signing.xcconfig"

cat > "$work/bin/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == "build ios --release" ]]
[[ ! ${MAPS_IOS_API_KEY+x} ]]
if [[ -n "${EXPECT_MAPS:-}" ]]; then
  [[ "$4 $5" == "--no-codesign --dart-define=OSRA_TEST=true" ]]
  [[ "$6" == --dart-define-from-file=* ]]
  grep -Fxq '{"MAPS_API_KEY":"fake-ios-maps-key"}' "${6#*=}"
  grep -Fxq "#include \"$EXPECTED_XCCONFIG\"" "$XCODE_XCCONFIG_FILE"
  grep -Fxq 'MAPS_API_KEY = fake-ios-maps-key' "$XCODE_XCCONFIG_FILE"
else
  [[ "$#" == 4 && "$4" == "--no-codesign" ]]
  [[ "$XCODE_XCCONFIG_FILE" == "$EXPECTED_XCCONFIG" ]]
fi
exit "${FLUTTER_EXIT:-0}"
EOF
chmod +x "$work/bin/flutter"

export XCODE_XCCONFIG_FILE="$EXPECTED_XCCONFIG"
MAPS_IOS_API_KEY= bash "$build_script" ios --release --no-codesign
EXPECT_MAPS=1 MAPS_IOS_API_KEY=fake-ios-maps-key \
  bash "$build_script" ios --release --no-codesign --dart-define=OSRA_TEST=true
status=0
EXPECT_MAPS=1 FLUTTER_EXIT=17 MAPS_IOS_API_KEY=fake-ios-maps-key \
  bash "$build_script" ios --release --no-codesign --dart-define=OSRA_TEST=true || status=$?
[[ "$status" == 17 ]]
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
if MAPS_IOS_API_KEY=fake-ios-maps-key bash "$build_script" ios --release \
    --no-codesign --dart-define=MAPS_API_KEY=other-key >/dev/null 2>&1; then
  echo "A second Maps Dart define unexpectedly succeeded" >&2
  exit 1
fi
echo "iOS Maps build wrapper passed: missing key, both build inputs, signing settings, and cleanup"
