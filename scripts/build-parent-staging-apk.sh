#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${API_BASE:-}" ]]; then
  echo "::error::Set the staging API base URL"
  exit 1
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  echo "::error::Set the APK versionCode"
  exit 1
fi
if [[ "${CI_SYNTHETIC:-0}" != "1" && -z "${OSRA_EXPECTED_SIGNER_SHA256:-}" ]]; then
  echo "::error::Set the lab signer certificate digest for the real staging build"
  exit 1
fi
if [[ "${CI_SYNTHETIC:-0}" != "1" && ! "$OSRA_EXPECTED_SIGNER_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  echo "::error::OSRA_EXPECTED_SIGNER_SHA256 must be exactly 64 hexadecimal characters"
  exit 1
fi

if [[ "$API_BASE" != "https://api.staging.osratech.com" ]]; then
  echo "::error::API_BASE must be exactly https://api.staging.osratech.com for this staging build"
  exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::BUILD_NUMBER must be a positive integer"
  exit 1
fi
if [[ "${CI_SYNTHETIC:-0}" == "1" ]]; then
  unset OSRA_UPLOAD_KEYSTORE OSRA_UPLOAD_KEYSTORE_PASSWORD OSRA_UPLOAD_KEY_ALIAS OSRA_UPLOAD_KEY_PASSWORD
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/apps/parent-app"
CONFIG="android/app/google-services.json"
APK="build/app/outputs/flutter-apk/app-release.apk"
VALUES_XML="build/app/intermediates/packaged_res/release/packageReleaseResources/values/values.xml"
BADGING="$(mktemp)"
PERMISSIONS="$(mktemp)"
SIGNER_LOG="$(mktemp)"
trap 'rc=$?; rm -f "$BADGING" "$PERMISSIONS" "$SIGNER_LOG"; exit $rc' EXIT

if [[ -z "${AAPT:-}" ]]; then
  AAPT="$(python - "$ANDROID_HOME/build-tools" <<'PY'
import os, sys
base = sys.argv[1]
versions = sorted(os.listdir(base), key=lambda value: [int(part) for part in value.split(".")])
print(os.path.join(base, versions[-1], "aapt"))
PY
)"
fi
if [[ -z "${APKSIGNER:-}" ]]; then
  APKSIGNER="$(python - "$ANDROID_HOME/build-tools" <<'PY'
import os, sys
base = sys.argv[1]
versions = sorted(os.listdir(base), key=lambda value: [int(part) for part in value.split(".")])
print(os.path.join(base, versions[-1], "apksigner" + (".bat" if os.name == "nt" else "")))
PY
)"
fi

python - "$CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
    assert config["project_info"]["project_id"]
    clients = config["client"]
    assert any(
        client["client_info"]["android_client_info"]["package_name"] == "com.osratech.parent"
        for client in clients
    )
except (OSError, KeyError, IndexError, AssertionError, json.JSONDecodeError) as error:
    raise SystemExit(f"::error::Firebase config is missing or does not name com.osratech.parent: {error}")
print("Firebase config names com.osratech.parent (values withheld)")
PY

rm -f "$VALUES_XML"
flutter build apk --release --build-number="$BUILD_NUMBER" --dart-define=API_BASE="$API_BASE"

python - "$CONFIG" "$VALUES_XML" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

config_path, values_path = sys.argv[1:]
try:
    with open(config_path, encoding="utf-8") as handle:
        config = json.load(handle)
    values = {
        element.attrib["name"]: element.text
        for element in ET.parse(values_path).getroot().findall("string")
    }
    assert values.get("project_id") == config["project_info"]["project_id"]
    expected_app_ids = {
        client["client_info"]["mobilesdk_app_id"]
        for client in config["client"]
        if client["client_info"]["android_client_info"]["package_name"] == "com.osratech.parent"
    }
    assert values.get("google_app_id") in expected_app_ids
except (OSError, KeyError, IndexError, AssertionError, ET.ParseError, json.JSONDecodeError) as error:
    raise SystemExit(f"::error::release Firebase resources are missing or stale: {error}")
print("Generated Firebase resources match the input config (values withheld)")
PY

[[ -f "$APK" ]] || { echo "::error::$APK is missing"; exit 1; }
"$AAPT" dump badging "$APK" > "$BADGING"
grep -q "package: name='com.osratech.parent' versionCode='${BUILD_NUMBER}'" "$BADGING" || {
  echo "::error::APK package/version does not match com.osratech.parent versionCode ${BUILD_NUMBER}"
  exit 1
}
"$AAPT" dump permissions "$APK" > "$PERMISSIONS"
grep -q "name='android.permission.INTERNET'" "$PERMISSIONS" || { echo "::error::INTERNET is missing"; exit 1; }
grep -q "name='android.permission.POST_NOTIFICATIONS'" "$PERMISSIONS" || { echo "::error::POST_NOTIFICATIONS is missing"; exit 1; }
if [[ "$APKSIGNER" == *.bat ]]; then
  cmd.exe //c "$APKSIGNER" verify --print-certs "$APK" > "$SIGNER_LOG"
else
  "$APKSIGNER" verify --print-certs "$APK" > "$SIGNER_LOG"
fi

if [[ "${CI_SYNTHETIC:-0}" != "1" ]]; then
  if ! grep -Fxi "Signer #1 certificate SHA-256 digest: ${OSRA_EXPECTED_SIGNER_SHA256}" "$SIGNER_LOG" > /dev/null; then
    echo "::error::APK signer does not match the Lab Parent certificate"
    exit 1
  fi
fi

python - "$APK" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    digest = hashlib.file_digest(handle, "sha256")
print(f"{digest.hexdigest()} *{sys.argv[1]}")
PY
echo "Parent staging APK verified: package, versionCode ${BUILD_NUMBER}, Firebase resources, INTERNET, POST_NOTIFICATIONS and signer"
