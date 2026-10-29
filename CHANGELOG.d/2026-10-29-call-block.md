### Child agent — a blocked app can't take or keep a call (#444, Karim's rule of 29 Oct)
- **C1, a blocked app rings.** On an unlocked phone the agent sends the notification's own `CallStyle`
  decline intent, once per ring, and covers the screen until the ringing stops (on the Flip4 the block
  screen alone was answered through in 1.1 s). On the lock screen, where the event carries no details,
  the cover goes up when the last notification before the ring came from a blocked app. It is dropped
  at once if the dialer or an emergency app posts, so a real phone call is never covered.
- **C2, a blocked call connects anyway.** The cached `CallStyle` hang-up intent is sent when the audio
  mode turns to a call. If none was cached (locked), the first notification that carries one sends it. A
  call still up after 15 s sends the parent one `block_bypass` alert with `layout: call`, at most once per
  app per ten minutes.
- **C3, the block arrives mid-call.** A call that connected before its app was blocked is left alone until
  it ends; after that the app is blocked like any other.
- The accessibility service now also receives notification events. From another app's notification the
  agent reads only the category, the ongoing flag, the post time and the three `CallStyle` intents, never
  the title, text or people. No NotificationListener is needed, so this works in the Play build.
- `CallBlockPolicy` is pure; `CallBlockPolicyTest` has 11 rows for C1–C3, including the dialer and the
  silent-ring time limit.
