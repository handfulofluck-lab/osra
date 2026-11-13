### Android child — a lifted block screen no longer comes back when the ring or the keyguard closes (#671)
- The block screen takes itself down when the current rules no longer block the app it is showing, checked
  on `onResume` (it has just been uncovered) and on `onStop` (the child left it with Home). On the Flip4
  (scenario run 1 on #665) the child read "This app is blocked by your parent · Calculator" at 19:10Z,
  seven minutes after the parent lifted the block at 19:04Z, on the `BlockActivity` record from 19:03Z.
- The screen now owns a task of its own and stays out of Recents — as do the lock, ring and SOS screens.
  They all shared the application's task before, which is why closing one uncovered another; now closing
  one returns to the home screen or the app that was really underneath.
- Fail-closed by construction: the re-check is the same rule walk that raised the screen, so **no cached
  rules while paired** (AND-03) and **a snapshot that has not synced yet** both answer "still blocked" and
  the screen stays. A screen that cannot name its package stays too. Only an explicit ALLOW closes it; a
  daily limit that is still reached keeps it. `BlockRecheckPolicy` is the table, `BlockRecheckPolicyTest`
  the rows.
- Verified by the JVM suite only: `testPlayDebugUnitTest` / `testFullDebugUnitTest` green, with the
  mutants recorded next to each test. Measured, one row red apiece: removing the `onResume` call →
  `the block screen re-checks when it comes back to the front`; `decision != BLOCK` in place of
  `decision == ALLOW` → `a resumed screen stays while the daily limit is still reached`; deleting
  `android:taskAffinity=""` from `BlockActivity` → only `the block screen is the root of its own task and
  stays out of recents`; deleting `android:excludeFromRecents="true"` from `RingActivity` → only
  `the ring screen is the root of its own task and stays out of recents`. **Not verified on a handset**:
  the phone row is SC-1.4 then SC-1.8 in one pairing on the Flip4, expecting the home screen or the
  previous app in front after the ring stops, and the same after an unlock.
