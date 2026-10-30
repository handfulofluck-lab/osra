### Child agent — the pairing title no longer sits under the status bar (#440 follow-up)
- With `targetSdk 35`, Android 15 draws every activity edge to edge. The pairing form's and the PIN step's
  title overlapped the clock on the Flip4. The pairing screen's root now adds the status bar, navigation
  bar, display cutout and keyboard insets to its own 16 dp padding (`SystemBarPadding`).
- `SystemBarPaddingTest` pins the arithmetic and that `PairingActivity` applies the insets.
