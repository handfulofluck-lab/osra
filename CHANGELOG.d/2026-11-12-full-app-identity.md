### Child agent — the Full build is its own app, with its own key (ADR-0039 D1, D2; roadmap 5.10 PR A, part 1)
- **The Full artefact is `com.osratech.child.full`** (`applicationIdSuffix = ".full"`) with version name
  `0.2.0-full`. The Play build keeps `com.osratech.child`, and `namespace` and every Kotlin package stay
  `com.familyshield.agent`, so no source file, proguard keep or manifest component moves.
  `EssentialPackages.OWN_PACKAGE` already derives from `BuildConfig.APPLICATION_ID`, so the agent still
  recognises itself in both builds.
- **Proof from the built artefact, not from the build file:**
  `aapt2 dump badging app-full-release.apk` → `package: name='com.osratech.child.full' versionCode='2'
  versionName='0.2.0-full'`.
- **The Full build has its own signing key**, read from `OSRA_FULL_KEYSTORE`, `_PASSWORD`, `OSRA_FULL_KEY_ALIAS`
  and `OSRA_FULL_KEY_PASSWORD`. Play's upload key never signs a Full artefact and the Full key never signs a
  store build; a half-configured Full key fails the build naming the missing variable, and a missing one falls
  back to the debug key with a warning that names **its own** four variables.
- **This is why the two ids matter:** the builds could only share one key if Play App Signing were given up or
  Play's key exported, and both are worse than a second id (ADR-0039 D1).
- Rows: the accessibility component test now takes the package half from `BuildConfig.APPLICATION_ID` rather
  than a literal, so it proves the artefact that ships instead of the one that used to. Both flavours' suites
  **987/987** with the suffix in place.
