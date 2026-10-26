### Android — the parent app can register a push token when Firebase config is present (#400)
- `com.google.gms.google-services` 4.4.2 is declared in `settings.gradle.kts` and applied in `:app` **only when
  `android/app/google-services.json` exists**. Without it, `firebase_messaging` has no default `FirebaseApp`, so
  `getToken()` returns nothing and no parent push token can register — the Flip4 notification row waits on this.
- Config stays out of the repository (#317): applying the plugin unconditionally makes
  `process<Variant>GoogleServices` fail the build on a clean clone, so a build without the file is unchanged and push
  is reported *absent* by `FcmPushTokenSource` rather than broken.
- **⚠️ measured here:** the release bundle builds without the file (that is the CI case). The with-config path is
  **not** measured — it needs a real `google-services.json`, which is Karim's queue, and Claude's device row.
