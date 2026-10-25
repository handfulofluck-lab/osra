### Android — a keyguard-only lock is refused, not reported as applied (#368, ADR-0034)
- On the Flip4 a `lock` reached a dozing phone in 1.6 s and was acked as applied, while
  `LockActivity` never appeared: `ActivityTaskManager: Background activity launch blocked!` (BAL_BLOCK,
  result 102, process state FOREGROUND_SERVICE). Nothing of ours could show, because the phone had
  neither the overlay permission nor our accessibility service — but **device admin was active**, so
  `lockNow()` returned true and `EnforceabilityPolicy.lockOutcome` named the keyguard as the path.
- The parent was told "locked" while the child's own unlock ended the lock screen. **ADR-0034** settled
  this yesterday: a keyguard-only lock is `unavailable`, whatever `lockNow()` returned.
- `lockOutcome` now applies only through the **overlay** or the **accessibility service** — the two
  paths that can show our screen — and refuses with `lock_screen_unavailable` otherwise. `adminLocked`
  stays in the signature because the dispatcher still calls `lockNow()` on that path, as a belt behind
  either of the two; it no longer decides the answer on its own.
- The ack therefore reports `failed` with `lock_screen_unavailable` in exactly the state #368 measured.
- Tests: the keyguard-only row now asserts the refusal, and the "strongest path" row names the overlay
  or the accessibility service. Mutant: put `adminLocked ->` back first and both rows fail.
