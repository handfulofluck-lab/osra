#!/bin/bash
# Mac step (ii), #775: builds the daemon and installs it as a launch daemon ON A TEST MAC. This is the test
# bed's installer, not the product's: the notarised installer is ADR-0036 build step (vi).
#
# Run as an administrator, from apps/child-ios/MacAgent:   sudo ./scripts/install-dev.sh
# It builds as the user who called sudo (never as root), then copies two files:
#   /Library/PrivilegedHelperTools/com.osratech.agent     root:wheel 0755
#   /Library/LaunchDaemons/com.osratech.agent.plist       root:wheel 0644
# and starts the job. A rebuilt binary is a different program to the System keychain, so an existing pairing
# is cleared first; pair again afterwards with:  sudo /Library/PrivilegedHelperTools/com.osratech.agent pair
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 77; fi
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then echo "run with sudo from an administrator account, not as root" >&2; exit 64; fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.osratech.agent"
BINARY="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

sudo -u "$SUDO_USER" swift build -c release --package-path "$HERE"
BUILT="$(sudo -u "$SUDO_USER" swift build -c release --package-path "$HERE" --show-bin-path)/osra-agent"
plutil -lint "$HERE/launchd/$LABEL.plist"

if launchctl print "system/$LABEL" >/dev/null 2>&1; then launchctl bootout "system/$LABEL" || true; fi
if [ -x "$BINARY" ]; then "$BINARY" unpair || true; fi

install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 0755 "$BUILT" "$BINARY"
install -o root -g wheel -m 0644 "$HERE/launchd/$LABEL.plist" "$PLIST"
launchctl bootstrap system "$PLIST"
launchctl print "system/$LABEL" | grep -E "state =|pid =" || true
echo "installed: $("$BINARY" version)"
