### Child agent — a debug-only call probe for the #444 measurements
- `CallProbe` logs, under the `CallProbe` tag, the four answers #444 needs before any call-blocking code:
  whether a blocked call app's `CATEGORY_CALL` notification reaches the accessibility service, whether a
  full-screen accessibility overlay draws above the call UI (off until an `adb` broadcast turns it on),
  which `CallStyle` hang-up intents and semantic actions the notification carries, and the audio mode
  while a call is up.
- Debug builds only: every entry point returns at once otherwise, and the shipped accessibility config is
  unchanged. `CallProbeReleaseTest` pins both.
