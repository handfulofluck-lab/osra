### CI — a published build's versionCode rises with every run (Play 5.2)
- **Before:** the child agent's `versionCode = 2` was a literal in `build.gradle.kts`, and the parent app's came
  from `pubspec.yaml`. Play refuses a second upload under a code it already has, so the second release of either
  app would have failed at upload time — the one failure mode that only shows up after signing and building.
- **After:** both release builds take the number from **their own workflow's run number**, which only ever
  increases. `OSRA_VERSION_CODE` feeds the child agent (`maxOf(value, 2)`, so a local build keeps reporting 2
  and can still be sideloaded), and `--build-number` feeds the parent bundle.
- **Each app has its own sequence**, because each is published by one workflow — `child-android.yml` for the
  child, `parent-app.yml` for the parent — so the two counters can never be confused for one another.
- **What this does not promise:** a *re-run* of the same workflow reuses its run number, and Play will refuse
  that upload. That is deliberate: two different builds must never share one versionCode.
- **CI proves the number reaches the artefact** (#591 review): the child job asserts `versionCode:'<run>'` in
  `aapt2 dump badging` for **both** release APKs, and the parent job asserts `android:versionCode="<run>"` in the
  merged release manifest. Without those, a broken wiring would only surface at upload.
- **Both workflows now say "do not rename this file"**: `run_number` restarts at 1 if the workflow is renamed or
  recreated, and Play would then refuse every upload until the count passed the old one.
- **Fixed while here:** the parent's `INTERNET` check was `grep -q ... && echo`, which under `set -e` cannot
  fail — a gate that looked present and did nothing. It now exits 1 with a message. `workflow-lint` had been
  warning about it; the warning is gone.
