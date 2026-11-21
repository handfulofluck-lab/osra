#!/usr/bin/env bash
# Classify one Xcode UI-test log for the #739 launch retry.
#
# Prints exactly one word and exits 0:
#   assertion   the case failed on its own assertions (XCTAssert / XCTest failure line)
#   launch      the app never launched (a simulator start failure) — the only case worth retrying
#   ambiguous   both kinds of evidence are present, so neither may be trusted
#   other       neither kind — red, and not something this retry is entitled to absorb
#
# Why this is a script and not inline workflow shell (Codex, 7062415705): three review rounds found three
# defects in this classification, each invisible to every other check — a `printf` with two backslashes, the
# generic `Failing tests:` footer read as an assertion, and the retry's own failure never classified. A file can
# be tested; a heredoc inside YAML cannot.
#
# `Failing tests:` is deliberately NOT evidence of an assertion: xcodebuild prints that footer for a launch
# failure too, and the archived #949 run carried it alongside `Failed to launch`.
set -uo pipefail

log="${1:-}"
if [ -z "$log" ] || [ ! -f "$log" ]; then
  echo "other"
  exit 0
fi

has_assertion() { grep -qF 'XCTAssert' "$1" || grep -qF 'error: -[' "$1"; }
has_launch() {
  grep -qiE 'timed out while launching application|failed to launch|FBSOpenApplicationServiceErrorDomain|unable to launch the application' "$1"
}

a=0; l=0
has_assertion "$log" && a=1
has_launch "$log" && l=1

if [ "$a" -eq 1 ] && [ "$l" -eq 1 ]; then echo "ambiguous"; exit 0; fi
if [ "$a" -eq 1 ]; then echo "assertion"; exit 0; fi
if [ "$l" -eq 1 ]; then echo "launch"; exit 0; fi
echo "other"
