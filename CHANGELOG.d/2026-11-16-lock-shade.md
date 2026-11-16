### Android — the notification shade is not usable while the child is locked or paused (#828)
- Karim, Flip4, 15 Nov: the lock held for app opening, but the shade still opened over the lock overlay —
  every notification readable in full and WhatsApp's inline **Reply** working, so the child kept chatting
  while "locked".
- While a lock or pause is on, the agent's accessibility service now collapses the shade as it opens with
  `GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE` (API 31+). It is the narrow action: the phone app, the
  emergency dialer and a ringing call are untouched (an incoming call is a full-screen intent, not the
  shade), and the agent reads no notification content — it only sends the collapse.
- Below API 31 there is no such action, so the service does nothing there; that limit is stated in the
  code and held by a row rather than implied.
- Tests: the pure classifier (lock on, systemui unit names and class names, no lock, another package, an
  unnamed window, API 30) and a source row pinning that the service wires the policy to `LockState` and the
  dismiss action. The catalogue probe row (lock → open shade → inline reply refused within 1 s) is device
  evidence for the Flip4 run, not JVM evidence.
