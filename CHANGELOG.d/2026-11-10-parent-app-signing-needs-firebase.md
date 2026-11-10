### CI — the parent app's release build no longer fails while its Firebase secret is missing
- **Before:** since the upload keystore secrets were added (7 Nov), every `parent-app` run (pull requests, main,
  nightly) failed in `flutter build appbundle` with "google-services.json is missing for a signed release build",
  because `PARENT_GOOGLE_SERVICES_JSON_B64` is not set yet.
- **After:** the workflow hands the keystore to Gradle only when the Firebase config is there too. Without it the
  AAB builds with the debug key and the job prints a warning naming the missing secret. With both secrets set,
  the AAB is signed exactly as before. Same rule as #542 for the child agent.
- The Gradle guard (#400) does not change: a signed release without `google-services.json` is still refused.
