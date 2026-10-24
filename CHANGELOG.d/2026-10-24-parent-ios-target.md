### Parent app — the iOS target exists, and CI builds it for the simulator (#356)
- **`apps/parent-app/ios/` is generated** (`flutter create --platforms=ios --org dev.familyshield .`, Flutter
  3.47.1), so the parent app now has both platform folders over one `lib/`. Nothing in `lib/`, `test/` or the
  Android folder changed to make it build: the app was already platform-agnostic Dart.
- **The bundle identifier is `dev.familyshield.familyshieldParent`**, from the same org and the same leaf as the
  Android `applicationId` (`dev.familyshield.familyshield_parent`). The underscore is dropped because Apple's
  bundle-ID grammar allows only alphanumerics, hyphens and periods — Flutter does this conversion itself, and
  the generator's output was kept rather than forced back to an identifier App Store Connect would refuse.
- **`Info.plist` carries the display name `OSRA`** (matching the Android `app_name`) and
  `CFBundleLocalizations = [en, ar]`, which is what makes iOS report an Arabic locale to Flutter so the
  existing `AppLocalizations` and RTL rendering apply. The deployment target is **15.0**, the value this
  Flutter version's template writes; it was not lowered by hand.
- **`.github/workflows/parent-app.yml` gains a second job, `parent-app-ios`** (`runs-on: macos-14`):
  `flutter pub get`, then `flutter build ios --release --no-codesign`, then two assertions against the
  committed tree — the bundle id, and the `Info.plist` display name and both locales. It is a job inside the
  existing suite workflow rather than a new file, because it shares that suite's `paths:` list and
  `scripts/check-ci-paths.mjs` (0 problems, self-test 10/10) models one workflow per suite.
- **Push registration rides the route that already exists.** `POST /v1/me/push-token` has always accepted
  `platform: "ios"`, so the parent app gains `lib/api/push_api.dart` (a typed client for the three
  `/v1/me/push-token` routes) and `lib/push/push_registration.dart` (permission → token → forward, behind a
  `PushTokenSource` interface, wired into `AuthNotifier.bootstrap()`/`logout()`). **No push SDK is added and
  no token is minted in this build:** the only source that ships answers `unavailable` and makes no request,
  so sign-in behaviour is unchanged. `flutter test` **388 passed** (374 before, 14 new in
  `test/push_registration_test.dart`), `flutter analyze` clean.
- **What this is not.** No signing, no entitlements, no App Store archive, no APNs key. `--no-codesign` is a
  simulator-target build with no certificate and no Apple account, which is why it is free on a public
  repository. **The iOS build has never been run on this machine — there is no Xcode here, and
  `flutter build ios` on Windows does not even offer the subcommand — so the macOS CI job is the only
  evidence this target builds.** Roadmap 3.9 says so and stays short of done.
