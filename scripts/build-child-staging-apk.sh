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
  unset OSRA_FULL_KEYSTORE OSRA_FULL_KEYSTORE_PASSWORD OSRA_FULL_KEY_ALIAS OSRA_FULL_KEY_PASSWORD
fi

PYTHON="$(command -v python3 || command -v python)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/apps/child-android"
CONFIG="app/google-services.json"
APK="app/build/outputs/apk/full/release/app-full-release.apk"
VALUES_XML="app/build/generated/res/processFullReleaseGoogleServices/values/values.xml"
PACKAGED_VALUES_XML="app/build/intermediates/packaged_res/fullRelease/packageFullReleaseResources/values/values.xml"
BADGING="$(mktemp)"
PERMISSIONS="$(mktemp)"
RESOURCES="$(mktemp)"
SIGNER_LOG="$(mktemp)"
trap 'rc=$?; rm -f "$BADGING" "$PERMISSIONS" "$RESOURCES" "$SIGNER_LOG"; exit $rc' EXIT

if [[ -z "${AAPT2:-}" ]]; then
  AAPT2="$("$PYTHON" - "$ANDROID_HOME/build-tools" <<'PY'
import os, sys
base = sys.argv[1]
versions = sorted(os.listdir(base), key=lambda value: [int(part) for part in value.split(".")])
print(os.path.join(base, versions[-1], "aapt2" + (".exe" if os.name == "nt" else "")))
PY
)"
fi
if [[ -z "${APKSIGNER:-}" ]]; then
  APKSIGNER="$("$PYTHON" - "$ANDROID_HOME/build-tools" <<'PY'
import os, sys
base = sys.argv[1]
versions = sorted(os.listdir(base), key=lambda value: [int(part) for part in value.split(".")])
print(os.path.join(base, versions[-1], "apksigner" + (".bat" if os.name == "nt" else "")))
PY
)"
fi

"$PYTHON" - "$CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
    if not config["project_info"]["project_id"]:
        raise ValueError("project_info.project_id is empty")
    if not config["project_info"]["project_number"]:
        raise ValueError("project_info.project_number is empty")
    clients = config["client"]
    if not any(
        client["client_info"]["android_client_info"]["package_name"] == "com.osratech.child.full"
        for client in clients
    ):
        raise ValueError("no client entry for com.osratech.child.full")
except (OSError, KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"::error::Firebase config is missing or does not name com.osratech.child.full: {error}")
print("Firebase config names com.osratech.child.full (values withheld)")
PY

rm -f "$VALUES_XML" "$PACKAGED_VALUES_XML"
OSRA_API_BASE="$API_BASE" OSRA_VERSION_CODE="$BUILD_NUMBER" ./gradlew assembleFullRelease --console=plain

"$PYTHON" - "$CONFIG" "$VALUES_XML" <<'PY'
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
    if values.get("project_id") != config["project_info"]["project_id"]:
        raise ValueError("generated project_id does not match input config")
    if values.get("gcm_defaultSenderId") != config["project_info"]["project_number"]:
        raise ValueError("generated gcm_defaultSenderId does not match input config")
    expected_app_ids = {
        client["client_info"]["mobilesdk_app_id"]
        for client in config["client"]
        if client["client_info"]["android_client_info"]["package_name"] == "com.osratech.child.full"
    }
    if not expected_app_ids or values.get("google_app_id") not in expected_app_ids:
        raise ValueError("generated google_app_id does not match com.osratech.child.full input config")
except (OSError, KeyError, IndexError, TypeError, ValueError, ET.ParseError, json.JSONDecodeError) as error:
    raise SystemExit(f"::error::release Firebase resources are missing or stale: {error}")
print("Generated Firebase resources match the input config (values withheld)")
PY

[[ -f "$APK" ]] || { echo "::error::$APK is missing"; exit 1; }
"$AAPT2" dump badging "$APK" > "$BADGING"
grep -q "package: name='com.osratech.child.full' versionCode='${BUILD_NUMBER}'" "$BADGING" || {
  echo "::error::APK package/version does not match com.osratech.child.full versionCode ${BUILD_NUMBER}"
  exit 1
}
grep -q "targetSdkVersion:'35'" "$BADGING" || {
  echo "::error::APK does not target SDK 35"
  exit 1
}
"$AAPT2" dump permissions "$APK" > "$PERMISSIONS"
grep -q "name='android.permission.INTERNET'" "$PERMISSIONS" || { echo "::error::INTERNET is missing"; exit 1; }
grep -q "name='android.permission.BIND_NOTIFICATION_LISTENER_SERVICE'" "$PERMISSIONS" || {
  echo "::error::BIND_NOTIFICATION_LISTENER_SERVICE is missing (not Full flavour)"
  exit 1
}
"$AAPT2" dump resources "$APK" > "$RESOURCES"
grep -q "string/google_app_id" "$RESOURCES" || { echo "::error::google_app_id is missing from packaged APK resources"; exit 1; }
grep -q "string/gcm_defaultSenderId" "$RESOURCES" || { echo "::error::gcm_defaultSenderId is missing from packaged APK resources"; exit 1; }

if [[ "$APKSIGNER" == *.bat ]]; then
  cmd.exe //c "$APKSIGNER" verify --print-certs "$APK" > "$SIGNER_LOG"
else
  "$APKSIGNER" verify --print-certs "$APK" > "$SIGNER_LOG"
fi

if [[ "${CI_SYNTHETIC:-0}" != "1" ]]; then
  if ! grep -Fxi "Signer #1 certificate SHA-256 digest: ${OSRA_EXPECTED_SIGNER_SHA256}" "$SIGNER_LOG" > /dev/null; then
    echo "::error::APK signer does not match the Lab Child Full certificate"
    exit 1
  fi
fi

"$PYTHON" - "$APK" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(65536), b""):
        digest.update(chunk)
print(f"{digest.hexdigest()} *{sys.argv[1]}")
PY
echo "Child Full staging APK verified: package, versionCode ${BUILD_NUMBER}, targetSdk 35, generated Firebase values equal input config, packaged google_app_id and gcm_defaultSenderId resources present, INTERNET, BIND_NOTIFICATION_LISTENER_SERVICE, and signer"
