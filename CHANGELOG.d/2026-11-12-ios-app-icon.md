### iOS child agent — OSRA Kids has its app icon (#607)
- New `apps/child-ios/App/Assets.xcassets/AppIcon.appiconset` with the Kids export from #595 (every iPhone and
  iPad size, and the 1024 marketing icon, which has no alpha channel), and `ASSETCATALOG_COMPILER_APPICON_NAME:
  AppIcon` on the app target only.
- `check-app-bundle.py` now fails a build whose `.app` has no icon: `CFBundleIcons` must name an AppIcon file, and
  `AppIcon60x60@2x.png` and `Assets.car` must be in the bundle.
