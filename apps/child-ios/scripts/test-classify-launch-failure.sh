#!/usr/bin/env bash
# The five verdicts classify-launch-failure.sh must give. Runs anywhere bash does, including the workflow-lint
# job, so a change to the classifier is judged by a fixture rather than by a reviewer reading a regex.
#
# Each case is a log file whose content is what Xcode actually emitted in a real run or a review fixture:
#   pass-ish logs are not classified here — the workflow only calls this after a non-zero exit.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classify="$here/classify-launch-failure.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
expect() {
  local name="$1" want="$2" got
  got="$(bash "$classify" "$tmp/$name.log")"
  if [ "$got" = "$want" ]; then
    printf 'ok   %-28s %s\n' "$name" "$got"
  else
    printf 'FAIL %-28s want=%s got=%s\n' "$name" "$want" "$got"
    fail=1
  fi
}

# The archived #949 failure: a launch failure carrying the generic XCTest footer. The retry must run.
{
  echo "Failed to launch"
  echo "Failing tests:"
} > "$tmp/archived_flake.log"
expect archived_flake launch

# THE REAL LAUNCH TIMEOUT, copied from the run at e8697999 (18:17 UAE). XCTest formats it as an XCTest
# failure line, so `error: -[` cannot be assertion evidence — this line must classify as a launch failure and
# be retried, and it was the reason the job went red at that head.
{
  echo "/Users/runner/work/osra/osra/apps/child-ios/UITests/AgentLaunchTests.swift:24: error: -[OSRAAgentUITests.AgentLaunchTests testTheAppLaunchesToThePairingScreen] : Failed to launch <XCUIApplicationImpl: 0x104fcdf40 com.osratech.child at /x/OSRAAgent.app> via Xcode: Timed out while launching application via Xcode."
} > "$tmp/real_launch_timeout.log"
expect real_launch_timeout launch

# A real assertion failure, with unrelated Launch Services noise alongside it (Codex 7060451632).
{
  echo "t = 1.2s Unable to bootstrap the Launch Services database: 0x2d"
  echo "PinRulesSeededTests.swift:42: error: -[OSRAAgentUITests.PinRulesSeededTests testX] : XCTAssertTrue failed"
  echo "Failing tests:"
} > "$tmp/assertion_with_noise.log"
expect assertion_with_noise assertion

# Both kinds of evidence: neither may be trusted (Codex 7062415705).
{
  echo "Timed out while launching application via Xcode"
  echo "PinRulesSeededTests.swift:42: error: -[OSRAAgentUITests.PinRulesSeededTests testX] : XCTAssertTrue failed"
} > "$tmp/ambiguous.log"
expect ambiguous ambiguous

# Something else entirely: red, no retry.
{
  echo "error: the project is not configured for this scheme"
} > "$tmp/other.log"
expect other other

# The retry's own log, failing on an assertion after a launch failure (Codex 7062415705 finding 2).
{
  echo "PinRulesSeededTests.swift:42: error: -[OSRAAgentUITests.PinRulesSeededTests testX] : XCTAssertTrue failed"
} > "$tmp/retry_assertion.log"
expect retry_assertion assertion

# A missing log must not be read as a launch failure.
got="$(bash "$classify" "$tmp/does-not-exist.log")"
if [ "$got" = "other" ]; then printf 'ok   %-28s %s\n' missing_log other
else printf 'FAIL %-28s want=other got=%s\n' missing_log "$got"; fail=1; fi

exit "$fail"
