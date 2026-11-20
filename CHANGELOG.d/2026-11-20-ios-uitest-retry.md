### iOS — the launch case retries a simulator start once; every escape row stays red on its first failure (#739)
- A simulator launch timeout has cost two runs: #932 at a fold, and #949 where the smoke case failed before any app
  code ran. Both were the runner failing to get the app up, not the app failing once up.
- The retry is bounded to the one case that measures a start: `AgentLaunchTests` runs with
  `-retry-tests-on-failure -test-iterations 2`, and nothing else does. The escape rows run in a second invocation with
  `-skip-testing:OSRAAgentUITests/AgentLaunchTests` and no retry flags, so an assertion failure there is red at its
  first iteration.
- **A green job no longer hides a launch failure.** A passing case is run once, so two "started" lines mean the first
  attempt failed and the retry is why the job is green. A step reads the saved log and, when that happens, posts a
  warning annotation and a row in the job summary saying so.
- **The first attempt is preserved:** both invocations write `-resultBundlePath` bundles and the launch log is kept,
  and all of it is uploaded as `ios-ui-results-<run>-<attempt>` (7 days), so the retry's evidence survives the run.
- **The trade-off, stated rather than assumed:** a launch flake that happens inside a seeded row's `setUp` is no longer
  absorbed, and will fail the job. That is deliberate — the bound is the case we have evidence for. If a seeded row
  shows the same runner failure, the fix is to extend the bound with that evidence, not to retry the suite.
- Split out of #949 at Ahmed's request (his 7030240643), so a test change and a CI change are reviewed separately.
- Verified: the workflow lints clean and both invocations name the same scheme and derived-data path, so the second
  run reuses the build rather than compiling twice. **The retry has not fired in a real run yet**, because every case
  passed on its first iteration at the head that introduced it. The recipe that would prove the bound is in the PR
  body: plant an assertion failure in a seeded row and the job must go red with no second iteration.
