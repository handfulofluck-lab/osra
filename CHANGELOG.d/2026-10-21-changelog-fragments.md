### Process — changelog entries move to `CHANGELOG.d/` fragments (#279)
- Every PR used to add its entry to the single `[Unreleased]` block in `CHANGELOG.md`, so every merge
  conflicted with every other open PR. On 2026-10-21 that cost **three re-signatures** — resolving a conflict
  inside a file the PR itself edits changes its patch-id, so §6.5's carry-forward correctly refuses the old
  signature — and shipped **one duplicated entry** that only a reviewer caught.
- Entries are now one file per change, `CHANGELOG.d/<YYYY-MM-DD>-<slug>.md`, containing the entry verbatim.
  `node scripts/assemble-changelog.mjs` folds them into `[Unreleased]` newest-first at release, skips an
  entry whose text is already present, and deletes the fragments unless `--keep` is passed.
- A new CI job, `changelog-fragment`, fails a PR that changes code (`apps/`, `services/`, `scripts/`,
  `infra/`, `.github/workflows/`) without adding a fragment, and exempts a Markdown-only PR — demanding a
  changelog entry for a documentation sweep is how a rule gets ignored.
- `AGENTS.md` §3 and §8 and the PR template now say fragment rather than `CHANGELOG.md`; the reasoning and
  the "when it is owed" rule (per case: would a parent notice?) live in `CHANGELOG.d/README.md`.
