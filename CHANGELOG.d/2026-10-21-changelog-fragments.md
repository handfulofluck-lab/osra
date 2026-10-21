### Process — changelog entries move to `CHANGELOG.d/` fragments (#279)
- Every PR used to add its entry to the single `[Unreleased]` block in `CHANGELOG.md`, so every merge
  conflicted with every other open PR. On 2026-10-21 that cost **three re-signatures** — resolving a conflict
  inside a file the PR itself edits changes its patch-id, so §6.5's carry-forward correctly refuses the old
  signature — and shipped **one duplicated entry** that only a reviewer caught.
- Entries are now one file per change, `CHANGELOG.d/<YYYY-MM-DD>-<slug>.md`, containing the entry verbatim.
  `node scripts/assemble-changelog.mjs` folds them into `[Unreleased]` newest-first, skips an entry whose text
  is already present, and deletes the fragments unless `--keep` — including fragments a previous `--keep` run
  left behind, so `--check` cannot stay red for good.
- A new gate, `changelog-fragment`, fails a PR that changes code (`apps/`, `services/`, `scripts/`, `infra/`,
  `.github/workflows/`) without **adding** a fragment, treats Markdown under those trees as documentation
  (`services/ai-engine/EVAL.md` is the case that mattered), and exempts only a revert or a title that starts
  `feat(release): assemble the changelog` (a version suffix is allowed, because the release commit should name
  what it releases). It lives in `workflow-lint.yml`, which now also runs on `edited`: a gate that reads the PR
  title and does not re-run when the title changes leaves the red run of the old title standing.
- `check-pr-diff-scope.mjs` now classifies `CHANGELOG.d/` as documentation, so the fragment gate and the scope
  gate cannot contradict each other, and it no longer reads assembly's deletion of fragments as a stale-base
  revert — every fragment an assembly PR deletes arrived with a recent merge, so without that exemption every
  release would have failed the gate; `AGENTS.md` §3/§8, the PR template, `docs/RELEASING.md` and the docs index
  point at the new shape, and `CHANGELOG.d/README.md` keeps §8's per-case rule ("would a parent notice?").
