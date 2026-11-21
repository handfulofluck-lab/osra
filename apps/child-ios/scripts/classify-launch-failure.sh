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
# The simulator failing to drive the app at all, which XCTest also formats as an `error: -[` line. Seen twice on
# this programme: `e8697999` (launch) and `eb9e7fcf` (background assertion), and in both cases an identical tree
# passed on re-run (#926 attempt 2). It is neither an assertion nor a launch timeout, and calling it an assertion
# turned a runner stall into a red gate (20:18Z).
# Narrowed to what a real log has shown (Ahmed, after `930bb377`): a simulator that could not acquire a
# background assertion or could not boot. `test runner exited` and `lost connection to the test manager` were in an
# earlier list and are deliberately NOT here — an app that CRASHES at launch produces them too, and retrying would
# absorb a real crash as a stall. A crash classifies as `other`, which is red and not retried.
RUNNER_RE='failed to get background assertion|timed out while acquiring background assertion|failed to boot|unable to boot the simulator'

has_launch() { grep -qiE "$LAUNCH_RE" "$1"; }

# Assertion evidence is `XCTAssert`, OR any XCTest failure line (`error: -[`) that is NOT a launch failure.
# The second half matters: XCTest prints failures that never say `XCTAssert` — "failed: caught error", an
# expectation, a UI-testing failure — and treating only `XCTAssert` as evidence let one of those classify as
# `launch` (or `other`) and be retried (Antigravity, 19:33Z). The launch regex filters them out first, so a
# genuine launch timeout — which XCTest also formats as `error: -[` — stays a launch failure.
has_assertion() {
  grep -qF 'XCTAssert' "$1" && return 0
  # Two filters, and only the LAST one is quiet: a `-q` grep emits nothing, so a quiet grep in the middle
  # would hand an empty stream to the next one and report "no failure line" (which is how these two fixtures
  # first went red).
  grep -F 'error: -[' "$1" | grep -vEi "$LAUNCH_RE" | grep -qiEv "$RUNNER_RE"
}

has_runner() { grep -qiE "$RUNNER_RE" "$1"; }

a=0; l=0; r=0
has_assertion "$log" && a=1
has_launch "$log" && l=1
has_runner "$log" && r=1

# More than one kind of evidence is ambiguous: never guess which one to trust.
if [ $((a + l + r)) -gt 1 ]; then echo "ambiguous"; exit 0; fi
if [ "$a" -eq 1 ]; then echo "assertion"; exit 0; fi
if [ "$l" -eq 1 ]; then echo "launch"; exit 0; fi
if [ "$r" -eq 1 ]; then echo "runner"; exit 0; fi
echo "other"
