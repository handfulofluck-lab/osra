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
# TWO things are deliberately NOT evidence of an assertion, and both were learned from real logs:
#   `Failing tests:` — xcodebuild prints that footer for a launch failure too (the archived #949 run carried it
#     alongside `Failed to launch`).
#   `error: -[`     — XCTest formats EVERY failure that way, including a launch timeout. The run at
#     `e8697999` produced one line: "error: -[AgentLaunchTests …] : Failed to launch … Timed out while launching
#     application via Xcode", so treating that prefix as assertion evidence classified the very flake this
#     workflow exists to retry as `ambiguous` and failed the job (Antigravity, Codex 7062904614).
# Assertion evidence is therefore the assertion vocabulary itself: `XCTAssert`.
set -uo pipefail

log="${1:-}"
if [ -z "$log" ] || [ ! -f "$log" ]; then
  echo "other"
  exit 0
fi

LAUNCH_RE='timed out while launching application|failed to launch|FBSOpenApplicationServiceErrorDomain|unable to launch the application'

has_launch() { grep -qiE "$LAUNCH_RE" "$1"; }

# Assertion evidence is `XCTAssert`, OR any XCTest failure line (`error: -[`) that is NOT a launch failure.
# The second half matters: XCTest prints failures that never say `XCTAssert` — "failed: caught error", an
# expectation, a UI-testing failure — and treating only `XCTAssert` as evidence let one of those classify as
# `launch` (or `other`) and be retried (Antigravity, 19:33Z). The launch regex filters them out first, so a
# genuine launch timeout — which XCTest also formats as `error: -[` — stays a launch failure.
has_assertion() {
  grep -qF 'XCTAssert' "$1" && return 0
  grep -F 'error: -[' "$1" | grep -qiEv "$LAUNCH_RE"
}

a=0; l=0
has_assertion "$log" && a=1
has_launch "$log" && l=1

if [ "$a" -eq 1 ] && [ "$l" -eq 1 ]; then echo "ambiguous"; exit 0; fi
if [ "$a" -eq 1 ]; then echo "assertion"; exit 0; fi
if [ "$l" -eq 1 ]; then echo "launch"; exit 0; fi
echo "other"
