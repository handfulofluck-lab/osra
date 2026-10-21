# `CHANGELOG.d/` — one file per change

**Put your changelog entry here, not in `CHANGELOG.md`.**

Every entry used to go into `CHANGELOG.md`'s `[Unreleased]` block. That block is a single file that every
open PR edits, so every merge conflicted with every other branch. On 2026-10-21 that cost **three
re-signatures** — resolving a conflict inside a file the PR itself edits changes its patch-id, so
`AGENTS.md` §6.5's carry-forward correctly refuses the old signature — and it shipped **one duplicated
entry** that only a reviewer caught. A fragment is a file nobody else touches; the conflict cannot happen.

## What to write

Create `CHANGELOG.d/<YYYY-MM-DD>-<slug>.md` whose contents are the entry **verbatim** — the heading the
`CHANGELOG.md` uses, then the bullets:

```markdown
### Parent app — the digest preferences screen speaks Arabic (#277)
- 27 ARB keys cover every string on the screen: the three switches, the emails field, the timezone
  section, six snackbars, the test-digest dialog and the child-name fallback.
- The Arabic test found a real defect: the timezone dropdown overflowed by 75 px at 320 px in RTL.
```

No front matter, no metadata, no parser. The assembler concatenates.

**When a fragment is required:** any change under `apps/`, `services/`, `scripts/`, `infra/` or
`.github/workflows/`. A PR that only touches Markdown does not need one — a documentation sweep is its own
record. `scripts/check-changelog-fragment.mjs` enforces exactly that and prints the remedy when it fails.

**The number in the heading:** if you do not know the PR number when you write the file, leave the heading
without one and add it after opening the PR. Do not guess — on 2026-10-21 a PR was labelled `#276` in four
places while GitHub had given it `#277`.

## Assembling

```bash
node scripts/assemble-changelog.mjs           # insert every fragment into [Unreleased], delete the files
node scripts/assemble-changelog.mjs --keep    # insert, keep the files (for review)
node scripts/assemble-changelog.mjs --check   # exit 1 if fragments are pending
```

Fragments are inserted newest-first by filename, and an entry whose text is already in `CHANGELOG.md` is
skipped — so running it twice is safe. `--check` belongs in a release checklist, not in CI on every PR: a
fragment written in a PR is *supposed* to sit there until the release assembles it.

## Why not just stop writing entries

Because the reason is not the friction. `AGENTS.md` §8 asks for an entry when a parent would notice the
change; that question is asked per case, and the answer for `#247` was "no" and for `#253` was "yes".
Fragments change *where* the entry goes, not whether it is owed.
