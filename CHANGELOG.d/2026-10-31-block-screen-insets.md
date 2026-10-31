### Child agent — the block and lock screens keep their title clear of the status bar in landscape (#489)
- At `targetSdk 35` the overlays are drawn edge to edge. In landscape on the Flip4, the block screen's title
  sat under the status bar and was clipped. The root column of the block screen and of the lock/pause screen
  now adds the safe-drawing insets (system bars, display cutout, keyboard) before its own 32 dp padding,
  the same gap #455 closed for the pairing screen.
- `BlockScreenInsetsTest` pins the inset padding on both roots.
