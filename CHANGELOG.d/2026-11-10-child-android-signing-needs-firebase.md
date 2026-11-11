### CI — Android jobs no longer die at configuration while the Firebase secret is missing (#535)
- **Before:** once the upload keystore secrets existed, every `child-android` run (pull requests, main, nightly)
  failed at Gradle configuration with "google-services.json is missing for a signed release build", because
  `CHILD_GOOGLE_SERVICES_JSON_B64` is not set yet. No Android PR could be verified in CI.
- **After:** the workflow hands the keystore and its three passwords to Gradle together, and only when the
  Firebase config is there too. Without it the release APKs build with the debug key and the job prints a
  warning naming the missing secret. With both secrets set, the release is signed exactly as before.
- Neither Gradle guard changes: a signed release without `google-services.json` (#409) and a half-configured
  release (#412) are still refused. Also drops a copy-pasted "upload keystore materialised" line from the
  Firebase step.
