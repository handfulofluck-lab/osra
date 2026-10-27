### Android — a signed child-app release refuses to build without Firebase config (#409)
- The child agent builds four artefacts (`play`/`full` × debug/release). Without `google-services.json` the Google
  Services plugin is not applied, so `getToken()` returns nothing and no push token can register — silently. When a
  release keystore is configured, `assemblePlayRelease`/`assembleFullRelease` now fail naming the file instead.
- Debug variants still build config-less on purpose (#317), which is what CI uses.
- `child-android.yml` gains a `CHILD_GOOGLE_SERVICES_JSON_B64` step, because the guard would otherwise fail every release
  job the day `OSRA_UPLOAD_KEYSTORE_B64` appears.
- Measured here: with a keystore configured and no config file, Gradle stops at configuration with the sentence; without
  the keystore it configures normally.
