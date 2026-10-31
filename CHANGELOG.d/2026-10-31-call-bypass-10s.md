### Child agent — a blocked call is reported to the parent after 10 s, and the split-screen path shares the floor (#444)
- **C1–C3 already shipped** (`144ad76`): a blocked app's ring is declined and covered, a call that connects
  anyway is hung up, and a call still up after the report window sends **one** `block_bypass` tamper alert
  with `layout: call` through the per-app floor. This PR does not re-implement any of that.
- **Threshold 15 s → 10 s**, per Claude's 2026-10-31 ruling: ten seconds of `MODE_IN_COMMUNICATION` with the
  block screen up is long enough to skip a call that ends as the screen rises (the 51 s Flip4 case in #444
  still alerts) and short enough that a parent hears about it while it is happening. The row now asserts
  nothing fires at **9 999 ms** and one alert at **10 000 ms**, so the boundary is pinned rather than implied.
- **New row for the cross-path floor**: a `split_screen` alert followed by a `call` alert for the same app
  inside the ten-minute floor sends **once**. The existing row covered PiP → call; Claude asked for the
  split-screen half explicitly, and it is the layout a child actually reaches for.
- The audio mode is still read at the moment of the check (`CallEnforcer.currentMode()`) and passed into the
  pure policy as a `CallAudioMode`, so the rows can feed any mode without an `AudioManager`.
- **Not in it, by agreement:** muting, ducking or ending the call, and pressing the app's own hang-up button
  through accessibility. The agent tells the parent; it does not promise silence.
- **Open, needs a decision:** the parent-facing line ("blocking a call app stops new calls being seen, but an
  answered call can keep its sound") has no home in the parent app today — there is no help surface for it.
  It is not in this PR rather than invented into a screen; proposed places are Claude's call.
