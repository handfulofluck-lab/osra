### Android child — a lifted block screen no longer comes back when the ring or the keyguard closes (#671, #734)
- The block screen takes itself down when the current rules no longer block the app it is showing, checked
  on `onResume` (it has just been uncovered) and on `onStop` (the child left it with Home). On the Flip4
  (scenario run 1 on #665) the child read "This app is blocked by your parent · Calculator" at 19:10Z,
  seven minutes after the parent lifted the block at 19:04Z, on the `BlockActivity` record from 19:03Z.
- The **block, lock and SOS** screens now own a task each and stay out of Recents. They all shared the
  application's task before, which is why closing one uncovered another; now closing one returns to the
  home screen or the app that was really underneath.
- **The ring screen deliberately keeps the application's task** (#734). The first draft gave it its own
  task too, and Karim found what that costs on the Flip4 during this PR's own device row: with an affinity
  of its own the ring screen outlived Home in a hidden task the child could not reach, so a phone left
  ringing could not be silenced from the handset — the parent PIN lives on that screen. It stays where
  opening OSRA finds it again until it has a way back. `the ring screen keeps the app's own task, so the
  alarm can be stopped from the handset` is the row, and putting `android:taskAffinity=""` back reddens it
  and nothing else.
- Fail-closed by construction: the re-check is the same rule walk that raised the screen, so **no cached
  rules while paired** (AND-03) and **a snapshot that has not synced yet** both answer "still blocked" and
  the screen stays. A screen that cannot name its package stays too. Only an explicit ALLOW closes it; a
  daily limit that is still reached keeps it. `BlockRecheckPolicy` is the table, `BlockRecheckPolicyTest`
  the rows.
- No overlay can be started by another app: `android:exported="false"` is now asserted on all four
  (Fable's g10 — an exported block or lock screen is something any installed app could raise).
- Verified by the JVM suite only: `testPlayDebugUnitTest` green, with the mutants recorded next to each
  test. Measured, one row red apiece: removing the `onResume` call → `the block screen re-checks when it
  comes back to the front`; `decision != BLOCK` in place of `decision == ALLOW` → `a resumed screen stays
  while the daily limit is still reached`; deleting `android:taskAffinity=""` from `BlockActivity` → only
  `the block screen is the root of its own task and stays out of recents`; setting `android:exported="true"`
  on `BlockActivity` → only `no overlay screen can be started by another app`. **Not verified on a handset
  in full**: the phone row is SC-1.4 then SC-1.8 in one pairing on the Flip4, expecting the home screen or
  the previous app in front after the ring stops, and the same after an unlock.
