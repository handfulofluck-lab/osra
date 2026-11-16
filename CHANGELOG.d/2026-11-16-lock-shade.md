### Android — the notification shade is not usable while the child is locked or paused (#828)
- Karim, Flip4, 15 Nov: the lock held for app opening, but the shade still opened over the lock overlay —
  every notification readable in full and WhatsApp's inline **Reply** working, so the child kept chatting
  while "locked".
- **Collapse by default inside systemui** (Antigravity measured it, Fable ruled the shape): the class name
  cannot identify the shade — API 34 reports `android.widget.FrameLayout`, and One UI may report something
  else — so a positive list keeps failing open silently. Any `TYPE_WINDOW_STATE_CHANGED` from
  `com.android.systemui` while locked now sends the dismiss action unless a short non-shade list names the
  window (volume dialog, power menu). The action only closes the shade: measured with the power menu
  focused, the collapse left it untouched. A false match is a no-op; a missed match loses the guard.
- While a lock or pause is on, the agent's accessibility service now collapses the shade as it opens with
  `GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE` (API 31+). It is the narrow action: the phone app, the
  emergency dialer and an incoming call's ringing screen are untouched — with the screen on, Android draws
  a call as a systemui heads-up rather than a full-screen intent (UI/UX Bureau), so the collapse is skipped
  while `CallEnforcer` reports the phone **ringing**, and only then, and only when the notice comes from
  the **system default dialer** (Fable): any app could otherwise post a call-style notification and hold
  the exemption open at will. Notification removal is not observable through the accessibility stream, so
  the 45 s ceiling and the ongoing-form/mode changes close the window, and only the default dialer
  may move it in either direction, and that limit is stated rather
  than implied. Once a call is placed or answered the
  shade is locked again, so a call cannot be used to read notifications. The agent reads no notification
  content; it only sends the collapse.
- Below API 31 there is no such action, so the service does nothing there; that limit is stated in the
  code and held by a row rather than implied.
- **Silent and DND rings are exempt too** (Antigravity, Android 14 device run): under a silent ringer or
  DND, Telecom suppresses the ringtone for the whole ring, so `AudioManager.mode` stays `NORMAL` and the
  audio-mode check answered "not ringing" — the collapse then hid the incoming-call heads-up and its
  Answer. The call notification is the second signal: an incoming call posts `CATEGORY_CALL` with
  `EXTRA_DECLINE` and no `EXTRA_HANG_UP`, so a bounded 45-second window starts from that notice, and it
  is cleared the moment the call is answered or another is placed. No permission is added (the Play
  flavour has no `READ_PHONE_STATE` and does not need it for this).
- Tests: the pure classifier (lock on, systemui unit names and class names, an unnamed systemui window,
  no lock, another package, a named non-shade systemui window, API 30) and a source row pinning that the
  service wires the policy to `LockState`, `CallEnforcer.isRinging()` and the dismiss action.
- **Honest limit (Kimi's review):** the collapse is reactive. The shade is drawn for at least one frame
  before the accessibility event lands, so what this guarantees is that the shade closes before it can be
  used deliberately; it does not prove that a tap landing inside the first frame cannot register. The
  catalogue probe row (lock → open shade → inline reply refused within 1 s) is the evidence for that
  claim and is owed on the Flip4, not JVM evidence.
