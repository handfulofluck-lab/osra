### iOS — two UI rows reach the PIN gate's lock, which nothing had reached before (#739)
- Catalogue KP01 asks for the lock that follows five wrong PINs. Until now `PinLockout` and `PinGateMessage`'s
  `.locked` arm were covered by unit tests only: no UI row ever made a fifth wrong attempt, so the sentence a child
  actually sees was never on a screen in CI.
- Row A: four wrong PINs must leave 4, 3, 2 and 1 tries, and the fifth must produce the app's own locked line at
  `PinLockout.firstDelay` and keep the field on screen. Mutants it catches: `freeAttempts` moved from 5 to 6, or the
  `locked` return in `ParentPinStore.check` deleted.
- Row B: while locked the PIN is not compared, so a second tap inside the first delay must report the *remaining*
  time. The row asserts the line is a different member of the shorter delays rather than parsing a numeral out of it,
  because the Arabic `one` and `two` arms carry no numeral. Mutants: `check` returning `firstDelay` instead of
  `remaining`, or the view holding its first `message`.
- The gate sequence (swipe to repair, open the gate, submit a wrong PIN) moved into shared helpers so the relaunch
  row and the two new rows cannot drift apart.
- No app code changed and no new user-facing text: every assertion is against a line the catalogue already renders.

### Follow-up: the two lock rows became one, and a seeded launch no longer animates (#739)
- The first version was two rows, each reaching the lock from a fresh seeded launch. Antigravity measured what that
  cost: with every request failing against the seed's discard port the status screen never idles, so XCUITest paid its
  60-second animation timeout on **every** interaction and one wrong-PIN submission took about six minutes. Ten
  submissions hit the job's 30-minute ceiling; five do not.
- The two rows are now one (`testTheGateLocksOnTheFifthWrongPinAndCountsDownInsideTheLock`). Both mutants still die:
  `freeAttempts` 5 → 6 fails the lock assertion, and `check` returning `firstDelay` instead of `remaining` fails the
  countdown assertion.
- The wait itself is fixed where it belongs: `UITestSeed.apply` turns animations off for a **seeded launch only**. The
  file is `#if DEBUG`, the call is inside the argument guard, and nothing changes in Release or without the argument.
