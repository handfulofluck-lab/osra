### Child agent — the SOS and reset-code screens keep their content clear of the status bar (#489 follow-up)
- The same edge-to-edge gap #492 closed for the block and lock screens: the SOS screen's and the reset-code
  screen's root column now adds the safe-drawing insets (system bars, display cutout, keyboard) before its
  own padding. On the reset-code screen the insets sit outside the scroll, so nothing scrolls under the bars.
- `BlockScreenInsetsTest` gains one row per screen.
