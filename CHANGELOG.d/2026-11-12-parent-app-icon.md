### Parent app — the OSRA logo replaces the Flutter default icon (roadmap 3.20)
- **Before:** the parent app's launcher icon on Android and iPhone was the Flutter default.
- **After:** the "Embrace" logo the maintainer chose on 2026-11-12, white ring and warm dot on Calm teal
  (`docs/design/BRAND.md`). Android 8+ gets an adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml`, a vector
  foreground on the `#0B5D57` ground); older launchers use the five mipmap PNGs. The 15 iPhone and iPad icon files
  are replaced in place, with no alpha channel.
- The files come from `scripts/brand/render.mjs` (the 3.20 brand PR); none is drawn by hand.
