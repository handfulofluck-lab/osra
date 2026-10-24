### CI — the parent app's macOS iOS build runs only when the iOS build's own inputs change (3.9)
- **New `ios-scope` job in `parent-app.yml`** (`ubuntu-latest`): on a pull request or a push to `main`, the
  `parent-app-ios` job (`macos-14`) now runs only when the change touches `apps/parent-app/ios/**`,
  `apps/parent-app/pubspec.yaml`, `apps/parent-app/pubspec.lock` or the workflow file. Every other parent-app change is
  Dart, which the Android release build in the same workflow already compiles.
- **Nightly and manual runs always build iOS**, so a Dart change or a new Flutter stable that breaks only iOS shows on
  `main` within a day. A diff that cannot be read builds rather than skips.
- **Why:** a macOS minute bills as ten Linux minutes once the repository is private (Karim's 2026-10-23 condition for
  the private move: trim CI first), and the iOS job takes 3–5 minutes on every parent-app run.
- `docs/TESTING.md` §4 (the workflow row and "When it runs") says when the job runs.
