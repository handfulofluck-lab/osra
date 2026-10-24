### CI — the child agent's release checks can fail again, and they read both release APKs (roadmap 1.8, #361)
- `child-android.yml` checks `targetSdk 35` in the `play` and the `full` release APK
  (`apk/<flavour>/release/app-<flavour>-release.apk`). It also checks that cleartext is off in the release
  config and on in the debug one. A missing APK or any failed check now fails the job. Since the flavour
  split, the step had read `apk/release/app-release.apk`, which no longer existed, and its `grep -q … && echo`
  guards could not fail under `bash -e`. So a release APK targeting 34 would have passed.
- The APK upload uses the flavoured paths and fails when it finds nothing. Until now it uploaded nothing
  and only warned, so the 14-day artefacts that `docs/RELEASING.md` R4 relies on were empty.
- `scripts/check-workflows.mjs --strict` warns on a `… && echo` guard placed before the last line of a
  run body, so this pattern cannot come back unnoticed.
- `docs/RELEASING.md` and `docs/TESTING.md` now cite the per-suite workflows instead of the old `ci.yml`
  lines. The release build and R4 use the flavoured APK names. E1 says that a suite the release commit did
  not touch has to be run by hand on that commit.
