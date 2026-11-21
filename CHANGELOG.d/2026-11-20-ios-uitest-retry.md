### iOS — one retry, and only when the simulator failed to launch the app (#739)
- A simulator launch timeout has cost two runs: #932 at a fold, and #949 where the smoke case failed with
  `Timed out while launching application via Xcode` *before any app code ran*. Both were the runner, not the app.
- **The first result is classified before anything is retried.** The launch case runs once, with no retry flags. If it
  passes, nothing else happens. If it fails and the log carries a launch failure (`Timed out while launching
  application`, `Failed to launch`, `FBSOpenApplicationServiceErrorDomain`, `Unable to launch`, `launch services`),
  that one case runs a second time. If it fails for any other reason — an assertion, a missing element, a timeout
  inside the test body — the step exits red on the **first** result and nothing is retried.
- The escape rows never retry: they run in a second invocation with `-skip-testing:OSRAAgentUITests/AgentLaunchTests`
  and no retry flags, so an assertion failure there is red at its first iteration.
- **A green job says which of the two happened.** The step writes a row to the job summary: "Passed on its first run"
  or "First run failed while launching the app on the simulator; retried once". A retry is therefore never silent.
- **Both results are preserved:** `launch-1` and `launch-2` each keep a `.xcresult` and a log, next to the escape
  rows' bundle, and all of it is uploaded as `ios-ui-results-<run>-<attempt>` for 7 days.
- **The trade-off, stated rather than assumed:** a launch flake inside a seeded row's `setUp` is not absorbed and will
  fail the job. The bound is the one case we have evidence for; widening it later needs that evidence.
- Split out of #949 at Ahmed's request (his 7030240643), so a test change and a CI change are reviewed separately.
- Verified: `check-workflows --strict` is clean. **Neither path has fired in a real run yet** — every run since has
  passed on its first launch. The recipe that proves both halves is in the PR body: restore the bare
  `-retry-tests-on-failure` and plant an assertion failure in the launch case, which must now go red first.

### The classifier became a script, because three reviews found three defects in it (#739)
- The retry decision lived in inline workflow shell, where nothing could test it. Three review rounds found three
  defects there, each invisible to every other check: a `printf` whose format carried two backslashes, the generic
  `Failing tests:` footer read as an assertion (which suppressed the very retry the workflow exists for), and the
  retry's own failure never classified, so a retry that died on an assertion was reported as the simulator failing.
- `apps/child-ios/scripts/classify-launch-failure.sh` now prints one word — `assertion`, `launch`, `ambiguous` or
  `other` — and the workflow branches on it. `apps/child-ios/scripts/test-classify-launch-failure.sh` runs six
  fixtures taken from real runs and review fixtures, and the existing **workflow-lint** job runs it: no new job, no
  new trigger, no simulator.
- **Both kinds of evidence stay red.** A log carrying an assertion and a launch failure is `ambiguous`, not a guess,
  and the retry's second log is classified as well, so "failed twice while launching" is only said when it is true.
