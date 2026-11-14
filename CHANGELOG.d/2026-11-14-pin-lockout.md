### The parent-PIN gate's wrong-try count survives the screen, and a lockout grows (#630, osra-security#24)
- The count of wrong parent-PIN tries used to live in a field on `TamperGuardActivity`, so **reopening the
  guarded screen handed back a fresh five tries**: settings, uninstall, re-pair and the ring's stop each
  opened a new activity. A 4-digit PIN is 10,000 values, so five tries per reopen with no delay between
  rounds is a matter of hours. The child-escape catalogue already required the fix — AG02 ("the attempt
  counter survives restarts; back-off grows") and E12 ("five wrong tries lock the gate for a while and
  alert the parent").
- The count, the time of the last failure and the failure count the parent was last alerted for now live in
  `PinAttemptStore`, over the **encrypted store beside the PIN hash** (`SecureStore`) — three integers, no
  new plaintext file and no new secret. `PinLockout` holds the rule free of Android types.
- **Five wrong tries close the gate for 1 minute, then 5, then 15, then 1 hour, and then flat.** While it
  is closed **every PIN is refused, the right one included** — a back-off that still accepts the right PIN
  is a delay, not a lockout. The count is deliberately *not* reset when a window expires, or a child gets
  1 minute, 1 minute, 1 minute forever by waiting; only a correct PIN clears it.
- A clock reading **earlier** than the last failure is inside the window, not outside it, so moving the
  phone's clock back does not open the gate.
- **One parent alert per lockout**, not one per attempt: the parent is told the gate closed, not told again
  for each further try inside the same closed gate.
- The child reads one line while the gate is closed — "Too many tries. Try again in N minutes, or ask your
  parent." — with no digits of the PIN and no count to work from.
- **Verified by JVM unit tests only** (`PinLockoutTest`, 9 rows, `testPlayDebugUnitTest` 9/9 green), with
  three planted faults each reddening its own rows and the tree restored afterwards: persisting nothing
  (2 rows red, including the survival row), `isLocked` always false (3 red), `shouldAlert` ignoring
  `alertedAt` (1 red). **Not verified on a handset**: that reopening the guarded screen on the Flip4 keeps
  the count, and that the closed gate refuses the right PIN inside the window. That row is owed and is not
  claimed here.
