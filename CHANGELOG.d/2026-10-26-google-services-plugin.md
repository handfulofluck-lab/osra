### Android — the parent app can register a push token when Firebase config is present (#400)
- `com.google.gms.google-services` 4.4.2 is declared in `settings.gradle.kts` and applied in `:app` **only when
  `android/app/google-services.json` exists**. Without it, `firebase_messaging` has no default `FirebaseApp`, so
  `getToken()` returns nothing and no parent push token can register.
- Config stays out of the repository (#317). Applying the plugin unconditionally makes
  `process<Variant>GoogleServices` fail on a clean clone, so a build without the file is unchanged and push is reported
  *absent* by `FcmPushTokenSource` rather than broken.
- **A signed release no longer ships without push.** When `OSRA_UPLOAD_KEYSTORE` is set — the upload path — a missing
  `google-services.json` now fails the build with that sentence, instead of producing an artefact with no token and no
  error (the #361 false-green pattern, applied to push).
- `parent-app.yml` gains a `PARENT_GOOGLE_SERVICES_JSON_B64` step, because the moment the upload keystore secret
  exists the guard above will refuse every release build that has no config.
- Measured by Claude on CI, both directions: no config → AAB builds and `google_app_id` is absent from
  `base/resources.pb`; a scratch config → AAB builds and `google_app_id` is present. Measured here: the no-config
  bundleRelease (58.4MB, 978s), and the guard firing when `OSRA_UPLOAD_KEYSTORE` is set.
