- **Parent app (iOS): Push Notifications entitlement and Firebase config hook (#558).** The parent iPhone app was
  signed with no `aps-environment` entitlement (found on the test iPhone with build 8, 16 Nov 2026), so iOS never issued
  an APNs token and `firebase_messaging` could not register for push. `Runner/Runner.entitlements` now declares
  `aps-environment` (`development`; an App Store / TestFlight export signs it as `production`), and every Runner
  configuration sets `CODE_SIGN_ENTITLEMENTS`. A new optional build phase copies `Runner/GoogleService-Info.plist` into
  the app when the build machine provides it; the file is gitignored and never committed (#317). Without it the build
  still succeeds and push stays "unavailable", as before. CI: `scripts/check-parent-ios-push.mjs` runs in the parent
  iOS job and fails if any of this goes missing. Not yet verified on a device: that needs a signed build with the
  Firebase config and the APNs key uploaded to Firebase.
