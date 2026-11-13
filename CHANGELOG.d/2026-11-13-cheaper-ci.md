### CI — cheaper closed-beta GitHub Actions (#613)
- Measured 31 days (2026-10-14T00:00Z → 2026-11-14T00:00Z) of `handfulofluck-lab/osra` Actions usage: **8696 runs,
  392.07h actual** across the **17 workflows with recorded runs** (18 workflow files exist in the current
  tree; see `docs/ops/ci-cost-2026-11.md` for the table and the 2026 USD rate model — untrimmed ≈ $666.26,
  trims 1+2 ≈ $392, Gradle ≈ $379–385, current-workflow-only ≈ $323).
- **iOS CI is now main-only and weekly.** `ios-ci.yml` `push` carries `branches: [main]` and its cron is
  Monday 01:23; every existing path pattern — `apps/child-ios/**`, `apps/parent-app/ios/**`, and the three
  API contract files — is unchanged, so the contract still breaks on its own PR.
- **The six build suites** (`api`, `parent-app`, `child-android`, `agent-desktop`, `ai-engine`,
  `api-image`) moved from daily to weekly Monday 02:11; `workflow_dispatch` stays, so a branch can always
  run by hand.
- **Android caching:** `child-android.yml` adds `gradle/actions/setup-gradle` right after `setup-java`,
  pinned to the full `v4.4.3` commit SHA `ed408507eac070d1f99cc633dbcf757c94c7933a`, reusing the safe
  default Gradle cache without touching the build commands or trusting a mutable tag in a secret-holding job.
- **Guardrail:** the new dependency-free `scripts/check-ci-cost-guardrails.mjs` (wired into
  `workflow-lint.yml`, self-test + real check) pins the main-only branch filter, the exact iOS paths, the
  seven weekly schedules, `cancel-in-progress: true` on all nine PR-suite workflows, including #608's macOS suite, and the setup-gradle
  step — so a cheaper edit that silently drops coverage turns red instead of saving money at the cost of a
  gate.
- Coverage is preserved: the iOS contract files still gate iOS CI, `check-ci-paths.mjs` still checks the
  path lists, and `probe-integrity` / `verified-gate` / `workflow-lint` behaviour is untouched.
