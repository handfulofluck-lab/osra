### Android — an incoming call is recognised on One UI while the ringer is silent (#851, Antigravity's finding)
- The shade collapse is exempted while a call is ringing, and the exemption's second signal — the incoming
  call's `CATEGORY_CALL` notification — was gated on `TelecomManager.defaultDialerPackage`. On Samsung One UI
  the notification is posted by `com.samsung.android.incallui`, while that API answers
  `com.samsung.android.dialer`, so on the Flip4 the window never opened under a silent or DND ringer and the
  collapse hid the incoming-call heads-up with its Answer.
- `IncomingRingWindow.fromTrustedSource` accepts the system default dialer **or** a platform in-call UI
  package (`EssentialPackages.inCallUi`, the same three the essential list already names). Fable's rule is
  unchanged: an ordinary app that posts a call-style notification still cannot open the exemption.
- Verified: `IncomingRingWindowTest` gains two rows — One UI's `incallui` sets the window in `NORMAL` mode,
  and a third-party package does not; the whole Android unit suite is green. Confirming the carrier state on
  the handset (`dumpsys telecom`, `logcat -b radio`) is still the device row's job, not this test's.
