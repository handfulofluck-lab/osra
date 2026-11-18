### CI — the setup-gradle pin rule covers every workflow, not just the Android suite (#911 follow-up)
- #912 added `gradle/actions/setup-gradle` to `parent-app.yml` and both of its verifiers found the same gap
  (Antigravity's M1): `scripts/check-ci-cost-guardrails.mjs` read `child-android.yml` **by name**, so the new
  pin in the parent-app workflow was unguarded — the `@v4` mutant survived the check.
- The rule now lives in one helper and applies to every workflow file the run reads: if
  `gradle/actions/setup-gradle@` appears anywhere, it must carry a full 40-character commit SHA and a version
  comment. `child-android.yml` keeps its two extra rules (the action must be present, and after `setup-java`).
- Measured, not assumed: unpinning the parent-app step in the working tree prints
  `ERROR parent-app.yml: setup-gradle must use a full 40-character commit SHA with a version comment` and the
  check exits 1; restoring it prints `0 problem(s)`. The self-test grows from 20 to 23 cases — an unpinned
  action in any workflow fails, a pinned one in any workflow passes, and a workflow with no `setup-gradle` is
  not a problem.
- No workflow behaviour changes: this only makes an existing rule apply where the action now appears.
