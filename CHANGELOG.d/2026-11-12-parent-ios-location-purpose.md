### Parent app on iPhone — the location purpose string App Store submission requires (#616)
- **Before:** the first TestFlight upload of the parent app (1.0.0 (1)) was rejected by Apple with
  **ITMS-90683**: `Runner.app`'s `Info.plist` carried no `NSLocationWhenInUseUsageDescription`. Apple's static
  scan flags any binary that references CoreLocation, and the Google Maps iOS SDK links it whether or not the
  app ever asks for a fix — so the app store submission fails on a capability the app does not use.
- **After:** `apps/parent-app/ios/Runner/Info.plist` declares the key with wording that is true and that App
  Review can read: *"OSRA does not use your location. The family map shows only where your child's phone is."*
  The same line ships localized in `en.lproj/InfoPlist.strings`, wired into the Xcode project as its own variant
  group (`project.pbxproj`, mirroring `Localizable.strings`), because a file in `en.lproj/` that the project does
  not reference is a file that never reaches the bundle.
- **The gate reads the built bundle, not the source.** `parent-app.yml`'s iOS job now asserts the key and a
  non-empty value in `build/ios/iphoneos/Runner.app/Info.plist`, and that `en.lproj/InfoPlist.strings` ships in
  the bundle with the same key — the same pattern that caught the missing push-alert strings in #410. An
  assertion on `ios/Runner/Info.plist` would have passed while the value never reached the bundle.
- **What was checked, so nothing else is added blind:** `pubspec.yaml` links one capability plugin,
  `google_maps_flutter`; `qr_flutter` renders the pairing code and never opens the camera, and there is no
  image picker and no geolocator, so no `NSCameraUsageDescription` and no photo-library key is needed. When
  the app does start reading the parent's own position, the string must change with it.
- **Arabic:** requested from the Arabic Language Bureau on #604 (`Bureau review:` line on the PR). The approved
  line goes into `ar.lproj/InfoPlist.strings` in a follow-up the same day; until then the English string is
  what iOS shows in every locale, which is honest and is what App Review reads.
