### iOS — the UI-test step retries a failing case once (#739)
- A simulator launch timeout has cost two runs: #932 at a fold, and #949 where the smoke case failed before any app
  code ran. Both were the runner failing to get the app up, not the app failing once up.
- The UI-test step now runs with `-retry-tests-on-failure -test-iterations 2`, so a case that fails is run once more
  and only two failures are reported.
- **The trade-off, stated rather than assumed:** a genuinely intermittent defect now has to fail twice before it is
  visible. That is the price of not re-running the whole job by hand each time the simulator stumbles, and it is
  cheaper than 19 minutes per stumble.
- Split out of #949 at Ahmed's request (his 7030240643), so a test change and a CI change are reviewed separately.
- Verified: the flag is present in the workflow and `check-workflows --strict` is clean; **it has not yet fired in a
  real run**, because every case passed on its first iteration at the head that introduced it.
