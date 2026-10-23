### CI — each suite runs when its own files change (Karim's 2026-10-23 decision: trim CI before the repo goes private)
- **The five build-and-test jobs left `ci.yml`** for their own files (`api.yml`, `parent-app.yml`, `child-android.yml`,
  `agent-desktop.yml`, `ai-engine.yml`), each with a `paths:` filter, a nightly run on `main` at 02:11 UTC and a manual
  run. The job bodies are moved unchanged. `ci.yml` keeps `probe-integrity`, which still runs on every PR.
- **`api-image.yml` builds the image only when its inputs change** (`services/api/**`, `packages/**`, the root package
  files, `.dockerignore`), plus nightly and by hand. It used to rebuild on every PR.
- **Why it is safe:** the only required check is `verified-gate`, which keeps running on every PR; a suite that did not
  run cannot block or bypass a merge. Measured on 16–23 Oct: the Android and Flutter jobs were about 60% of billed
  minutes, and most of those runs were on PRs that touched neither app.
- **New gate, `scripts/check-ci-paths.mjs`** (in `workflow-lint.yml`, self-test 10/10): fails when a suite's `push` and
  `pull_request` lists differ, when a list leaves out its own workflow file, when a workflow runs a repository file its
  list does not cover, when a test reads a file outside its suite's folder that the list does not cover, or when the API
  Dockerfile copies a source `api-image.yml` does not watch. It found the two cross-folder reads that a folder-only
  filter would have missed: the API's device-silence test reads two Android agent files, and the parent app's alert
  parity test (#344) reads `services/api/src/routes/alerts.ts`. Both are in the lists.
- `docs/TESTING.md` §4: the workflow table says what triggers each suite, and a new section explains the filters, the
  nightly run, the 300-file limit and how to add a suite.
