### Parent app — the push source behind the #356 seam, and a build without config says so (#360, roadmap 3.9)
- `FcmPushTokenSource` implements `PushTokenSource` on `firebase_messaging`. Sign-in now constructs
  `defaultPushSource()` instead of the always-`unavailable` stub, so **a build with a
  `google-services.json` registers a parent token** and `notifyParentsOfAlert` finally has a row to
  send to. Before this, nothing in the app ever called `POST /v1/me/push-token`, and every alert's
  parent push was a clean no-op over an empty table.
- **Three facts stay distinct**, which is the reason `PushPermission` has three values: no config in
  this build → `unavailable`; the parent declined the OS prompt → `denied`; granted but the token is
  still in flight → `noToken`. A build made from a clean clone has no config (the #317 rule keeps
  `google-services.json` out of the repository), so it reports `unavailable` — absent, not refused.
- The failed initialisation is latched, so a config-less build pays for it once rather than on every
  sign-in and every poll.
- Tests: `unavailable` (never `denied`) when initialisation throws, no token in that case, and the
  latch (mutant: drop it and the count is 3). Parent app `flutter test` 403 passed.
- **CI:** the iOS job moves from `macos-14` to `macos-15`, because `firebase_messaging` brings
  `FirebaseCoreInternal`, whose Swift 6 concurrency (`sending`, access-level imports) does not compile
  with the Xcode 15 that `macos-14` defaults to. The failing run pointed inside
  `Pods/FirebaseCoreInternal`, not at our code — the first thing adding the SDK broke, and the reason
  this job now pins a newer image.
- **Not in this PR:** the background handler (wake → `GET /v1/alerts` → local notification, silent on
  401) and the conditional Gradle plugin. It needs `flutter_local_notifications` and a real
  `flutter build apk`, and it is the half that makes a notification appear.
