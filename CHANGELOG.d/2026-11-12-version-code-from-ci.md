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
