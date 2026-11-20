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
