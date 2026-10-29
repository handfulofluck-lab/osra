### Child agent — a blocked app that stays on screen is pushed away or reported (#175)
- **Normal layout (the Meet call case):** a blocked app that comes back over the block screen is sent Home
  and covered again every time, at most once a second per app. Before, the overlay's retry budget gave
  up after three tries and the call carried on. `BlockRaisePolicy` makes the decision.
- **Picture-in-picture:** a PiP window stays above any full-screen activity, so the agent now also draws
  an opaque cover over the blocked PiP window (`PipCoverOverlay`). The cover follows the window if it
  moves and is removed when it closes. The agent also tries the window's own dismiss action and logs
  whether the phone accepted it.
- **PiP and split screen:** two raises per episode. If the blocked app is still visible after that, the
  parent gets one `tamper` alert, "A blocked app stayed on screen", with `metadata.type = block_bypass`
  and the app and layout. There is one alert per episode (dedupe key: device, app, layout, episode start), and at
  most one per app per ten minutes, so a PiP window that blinks out of the window list and back cannot page the
  parent again and again.
- Home is never sent while the window in front is essential (the dialer, emergency, the launcher): a blocked
  video in PiP over a phone call is covered and the block screen is raised, but the call is not thrown to Home.
- The lock overlay keeps its own bounded retry budget; only the block and time-limit screens changed.
- JVM: `BlockRaisePolicyTest` covers 14 cases, and `MultiWindowCoverageTest` adds three Home rows: no budget in the normal layout, the one-second spacing,
  exactly one bypass per episode, the cover added, moved and removed, and the alert key and metadata.
  On hardware (the Flip4 row, run by Claude): whether the cover sits above the PiP window on One UI.
