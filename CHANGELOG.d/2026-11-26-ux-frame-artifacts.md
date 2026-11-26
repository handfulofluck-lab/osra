### CI — the parent app publishes its UX frames as a build artifact (#1179)
- The `parent-app` job now runs the frame rows with `OSRA_FRAME_DIR` set and uploads the PNGs as
  `ux-frames-<sha>`, so the UI/UX Bureau can review a screen from the CI run that built it, with no
  machine and no local Flutter.
- Nothing changes when the variable is unset: the same rows run as ordinary tests and only assert that
  nothing overflows at 320 px / 200 %.
