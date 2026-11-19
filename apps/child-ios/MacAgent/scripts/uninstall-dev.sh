#!/bin/bash
# Removes what install-dev.sh put on a test Mac: the job, the binary, the plist and this Mac's side of the
# pairing. Run as an administrator:   sudo ./scripts/uninstall-dev.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 77; fi

LABEL="com.osratech.agent"
BINARY="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if launchctl print "system/$LABEL" >/dev/null 2>&1; then launchctl bootout "system/$LABEL" || true; fi
if [ -x "$BINARY" ]; then "$BINARY" unpair || true; fi
rm -f "$BINARY" "$PLIST"
echo "removed"
