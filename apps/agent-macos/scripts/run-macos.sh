#!/usr/bin/env bash
# FamilyShield macOS agent — dev run script (#25). Run on a Mac with .NET 8 SDK.
# Writes ~/Library/Application\ Support/FamilyShield/status.json every 60 s.
set -euo pipefail
cd "$(dirname "$0")/.."
exec dotnet run --project FamilyShield.Agent.MacOS.csproj "$@"
