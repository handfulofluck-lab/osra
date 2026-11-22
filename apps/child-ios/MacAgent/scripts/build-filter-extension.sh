#!/usr/bin/env bash
#
# Build and sign the Mac content filter through the Xcode host (roadmap 5.9, step (iii), #988).
#
# Replaces the first version of this script, which copied a SwiftPM dynamic library into `CFBundleExecutable`.
# That was the wrong route for a system extension: the system loads a bundle whose executable calls
# `NEProvider.startSystemExtensionMode()` and whose `NetworkExtension`/`NEProviderClasses` dictionary names the
# provider class (Codex, #989 `7073424029`, with Apple's host-bundle-layout reference). The route below is the
# one Apple documents: a host app that embeds the extension in `Contents/Library/SystemExtensions/`.
#
# NOT run in CI, and it cannot be: it needs Xcode, a Developer ID Application identity, and a provisioning
# profile carrying `com.apple.developer.networking.networkextension` =
# `content-filter-provider-systemextension`. CI's unsigned checks stay `swift build` / `swift test` in the
# package and `plutil -lint` on the two plists.
#
# Usage, on the test Mac:
#   CODESIGN_IDENTITY="Developer ID Application: <name> (TEAMID)" \
#   PROVISIONING_PROFILE=/path/to/profile.provisionprofile \
#   ./scripts/build-filter-extension.sh
#
# Then, as the Mac's administrator, run the host to submit the activation request:
#   <build>/OSRAMacHost.app/Contents/MacOS/OSRAMacHost
# and approve it once in System Settings → Privacy & Security.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:-}"
PROFILE="${PROVISIONING_PROFILE:-}"
OUT="${OUT_DIR:-.build/xcode}"

if [[ -z "$IDENTITY" ]]; then
  echo "CODESIGN_IDENTITY is required (a Developer ID Application identity)." >&2
  echo "An ad-hoc signature produces a bundle the system refuses to load." >&2
  exit 2
fi
if [[ ! -f "$PROFILE" ]]; then
  echo "PROVISIONING_PROFILE must point to a Developer ID profile carrying" >&2
  echo "com.apple.developer.networking.networkextension = content-filter-provider-systemextension." >&2
  exit 2
fi

plutil -lint FilterExtension/Info.plist
plutil -lint FilterExtension/OSRAFilter.entitlements
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 2; }

# The profile is per target, not global: a bare PROVISIONING_PROFILE_SPECIFIER applies to every target,
# including the host, which needs none. Xcode wants the profile's UUID rather than the file path, so it is
# read out of the profile itself instead of being asked for twice.
PROFILE_UUID="$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract UUID raw - 2>/dev/null || true)"
if [[ -z "$PROFILE_UUID" ]]; then
  echo "could not read the UUID from $PROFILE — is it a provisioning profile?" >&2
  exit 2
fi
echo "extension profile UUID: $PROFILE_UUID"

# Only the extension carries the Network Extension entitlement. The host is signed with the same identity
# and has none, so it works without a profile; if Xcode insists on one, a plain Developer ID profile for
# com.osratech.agent.host is enough and goes in OSRAMacHost_PROVISIONING_PROFILE_SPECIFIER.
xcodegen generate --spec project.yml --project .
xcodebuild \
  -project OSRAMacAgent.xcodeproj \
  -scheme OSRAMacHost \
  -configuration Release \
  -derivedDataPath "$OUT" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  OSRAMacHost_PROVISIONING_PROFILE_SPECIFIER="" \
  OSRAFilter_PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  OSRAFilter_CODE_SIGN_ENTITLEMENTS="$PWD/FilterExtension/OSRAFilter.entitlements" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  build

HOST_APP="$(find "$OUT/Build/Products/Release" -maxdepth 1 -name 'OSRAMacHost.app' -print -quit)"
EXTENSION="$(find "$HOST_APP/Contents/Library/SystemExtensions" -maxdepth 1 -name '*.systemextension' -print -quit)"
if [[ -z "$HOST_APP" || -z "$EXTENSION" ]]; then
  echo "the build did not produce a host app carrying a system extension" >&2
  exit 1
fi

# The extension's own signature is what the system checks on load, so it is signed explicitly — from the
# checked-in entitlements file, not from whatever the build resolved — and verified before the host around it
# is touched. Order matters: a host signed before its nested extension carries a stale seal.
codesign --force --timestamp --options runtime \
  --entitlements FilterExtension/OSRAFilter.entitlements \
  --sign "$IDENTITY" "$EXTENSION"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$HOST_APP"

codesign --verify --strict --verbose=2 "$EXTENSION"
echo "built $HOST_APP"
echo "carrying $EXTENSION"
echo "Next: run the host binary as the administrator and approve the extension in System Settings."
