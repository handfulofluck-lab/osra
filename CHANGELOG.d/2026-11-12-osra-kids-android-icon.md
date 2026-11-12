### Child app (Android) — the OSRA logo is the app icon, light for Play and dark for Full (roadmap 3.20)
- **Before:** `@drawable/ic_app` was a green shield with a tick, a 24dp vector that launchers could not mask.
- **After:** `@drawable/ic_app` is an adaptive icon of the "Embrace" logo the maintainer chose on 2026-11-12
  (`docs/design/BRAND.md`): a teal ring and warm dot on the light tint. The Full flavour overrides the three
  colours (`src/full/res/values/ic_app_colors.xml`) and shows the same mark on dark.
- The manifest is unchanged: it still names `@drawable/ic_app`, as `PlayManifestPolicy.APPLICATION_ICON` requires.
- Not yet seen on a phone: the Flip4 row for this change is the icon on the home screen and on the
  device-admin and accessibility sheets, in both flavours.
