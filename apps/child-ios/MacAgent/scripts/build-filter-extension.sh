#!/usr/bin/env bash
#
# Assemble the Mac content filter's `.systemextension` bundle around the SwiftPM-built payload, and sign it.
#
# Roadmap 5.9, step (iii), #988. This script is NOT run in CI and is not part of any gate: it needs a Developer
# ID Application identity and a provisioning profile that carries the Network Extension entitlement, neither of
# which exists in the repository or on a runner. Its job is to make the bundling route explicit instead of
# implied, so the signed device row starts from a known build rather than from an Xcode project nobody wrote.
#
# Usage, on the test Mac, after `xcrun devicectl`-era Xcode is installed:
#
#   CODESIGN_IDENTITY="Developer ID Application: <name> (<TEAMID>)" \
#   PROVISIONING_PROFILE=/path/to/OSRAFilter.provisionprofile \
#   ./scripts/build-filter-extension.sh
#
# Then, as the Mac's administrator (the parent), the extension is submitted by the daemon with
# `OSSystemExtensionRequest` and approved once in System Settings; approval is a person's action, not a script's.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:-}"
PROFILE="${PROVISIONING_PROFILE:-}"
OUT="${OUT_DIR:-.build/OSRAFilter.systemextension}"

if [[ -z "$IDENTITY" ]]; then
  echo "CODESIGN_IDENTITY is required (a Developer ID Application identity)." >&2
  echo "Without it the bundle would be ad-hoc signed and the system would refuse to load it." >&2
  exit 2
fi
if [[ ! -f "$PROFILE" ]]; then
  echo "PROVISIONING_PROFILE must point to a Developer ID profile carrying" >&2
  echo "com.apple.developer.networking.networkextension (content-filter-provider)." >&2
  exit 2
fi

plutil -lint FilterExtension/Info.plist
plutil -lint FilterExtension/OSRAFilter.entitlements

swift build -c release --product OSRAFilterProvider
PAYLOAD="$(swift build -c release --product OSRAFilterProvider --show-bin-path)/libOSRAFilterProvider.dylib"
if [[ ! -f "$PAYLOAD" ]]; then
  echo "the release build did not produce $PAYLOAD" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp FilterExtension/Info.plist "$OUT/Contents/Info.plist"
cp "$PROFILE" "$OUT/Contents/embedded.provisionprofile"
cp "$PAYLOAD" "$OUT/Contents/MacOS/OSRAFilterProvider"

# Hardened runtime and a timestamp, because a notarised installer (step vi) will not accept anything less.
codesign --force --timestamp --options runtime \
  --entitlements FilterExtension/OSRAFilter.entitlements \
  --sign "$IDENTITY" \
  "$OUT"

codesign --verify --strict --verbose=2 "$OUT"
echo "built $OUT"
echo "Next: submit it from the daemon with OSSystemExtensionRequest; approval is the parent's action."
