### Child agent — the block screen lands on top of Home, not behind it (#460)
- **What the child saw.** A blocked app opened, the app closed to Home, and the launcher appeared instead of
  the block screen — 4 times out of 4 on the Flip4, on both the old and the new package id. No "blocked by
  your parent" screen, no Request-access button, and on a build without the media enforcer YouTube audio
  kept playing behind Home. The app was still closed, so this was never a bypass; it was the feature
  silently not working.
- **Why.** `AccessibilityMonitorService` sent `performGlobalAction(GLOBAL_ACTION_HOME)` and then called
  `blocker.showBlockScreen(pkg)` immediately. Both are asynchronous and nothing ordered them, so whichever
  landed last won — and in the log it was Home.
- **The fix, in the pure policy.** `BlockRaisePolicy` now carries a **deferred raise**:
  `noteHomeSent(pkg, blocked, now)` records it, and `launcherFront(...)` returns it when a launcher is in
  front (the Home we asked for has landed) or when the **500 ms fallback** expires, for launchers that
  report no such event. The service raises from `onAccessibilityEvent` and from a `Handler` fallback, so the
  block screen goes on top of a launcher that is already there. The pending raise is cleared when it fires,
  which is what stops a launcher from re-raising the screen in a loop.
- **Rows.** H1: after Home the raise waits for the launcher, and does not fire on a non-launcher event. H2:
  one millisecond short of the fallback is still a wait, and the fallback raises. H3: a launcher event
  raises once, and two more launcher events raise nothing. H4: the case with no Home — a blocked window in
  the non-active pane — still raises immediately.
- **The issue's H4 was written for the wrong case, and the code is right.** It says "no `goHome` (PiP-only
  case)". PiP *does* send Home by #175's design ("each sending Home first in PiP"), so the deferral applies
  there too; the case that genuinely has no Home is a blocked window that is not the active one in the
  normal layout. The row tests that instead, and says so.
- **Faults, run not asserted.** No launcher gate → H1 and H2 red (both waiting rows, because removing the
  gate removes the wait they assert). No fallback → H2 alone. Pending not cleared → H3 alone. Byte-identical
  restore afterwards.
- **Not claimed:** the phone row. `docs/QA` row for the sitting: open a blocked app five times and confirm
  the block screen is in front every time with the launcher behind it.
