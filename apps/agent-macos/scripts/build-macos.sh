#!/usr/bin/env bash
# FamilyShield macOS agent — publish script (#25). Run on a Mac with .NET 8 SDK.
# Usage: ./scripts/build-macos.sh [osx-arm64|osx-x64]   (default: osx-arm64, Apple Silicon)
set -euo pipefail
cd "$(dirname "$0")/.."

RID="${1:-osx-arm64}"
case "$RID" in
  osx-arm64|osx-x64) ;;
  *) echo "unknown RID '$RID' (use osx-arm64 or osx-x64)" >&2; exit 1 ;;
esac

dotnet publish FamilyShield.Agent.MacOS.csproj -c Release -r "$RID" --self-contained true \
  -p:PublishTrimmed=false -o "dist/$RID"
echo "Published self-contained agent to dist/$RID (run ./dist/$RID/FamilyShield.Agent.MacOS)"
