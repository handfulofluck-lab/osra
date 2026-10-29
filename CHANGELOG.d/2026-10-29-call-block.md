### Child agent — a blocked app can't take or keep a call (#444, Karim's rule of 29 Oct)
- **C1, a blocked app rings.** On an unlocked phone the agent sends the notification's own `CallStyle`
  decline intent, once per ring, and covers the screen while it rings (on the Flip4 the block screen alone
  was answered through in 1.1 s). The cover lasts about 5 s if the decline ends the ring before it starts
  sounding, and at most a minute otherwise. On the lock screen, where the event carries no details, the
  cover goes up only when a blocked app posted within 5 s before the ring. Any allowed app, the dialer or
  an emergency app posting during the ring drops it at once, so an allowed call is never covered.
- **C2, a blocked call connects anyway.** The call belongs to the app that rang, or for an outgoing call to
  a call notification within 5 s of it, never to an older poster. Its cached `CallStyle` hang-up intent is
  sent; if none was cached (locked), the first notification that carries one sends it. A call still up
  after 15 s sends the parent one `block_bypass` alert with `layout: call`. That alert shares #443's
  per-app ten-minute floor (`BypassAlertFloor`), so a PiP alert and a call alert for one app page once.
- **C3, the block arrives mid-call.** A call that connected before its app was blocked is left alone until
  it ends; after that the app is blocked like any other.
- The accessibility service now also receives notification events. From another app's notification the
  agent reads only the category, the ongoing flag, the post time and the three `CallStyle` intents, never
  the title, text or people. No NotificationListener is needed, so this works in the Play build.
- `CallBlockPolicy` is pure; `CallBlockPolicyTest` has 16 rows for C1–C3, including the Flip4's
  `ongoing=true` ring, either order of ring event and RINGTONE, the stale-poster case, the short cover, the dialer and the shared floor.
