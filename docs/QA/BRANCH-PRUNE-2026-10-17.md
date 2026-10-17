# Branch prune list — Phase 0.5 (plan item 0.5)

**Purpose.** Plan 0.5 wants the remote branch list reduced to active lanes. This is the *list*, not the
deletion: nothing here changes the repository, and the deletion step needs the maintainer's go on the board.
It exists so that go can be given against a table rather than a guess.

## Method (reproducible)

```bash
git fetch origin --prune
git branch -r --merged   origin/main   # candidates: their tip commits are ancestors of main
git branch -r --no-merged origin/main   # must stay: content that is not on main
gh api "repos/handfulofluck-lab/osra/pulls?state=all&head=handfulofluck-lab:<branch>"   # the PR that carried it
```

A branch is **deletable** only when `--merged` says its tip is an ancestor of `main` *and* a merged PR
carried it. Deleting such a branch loses no commit: the commits stay reachable from `main`, and the full-ref
bundles under `~/osra-backups/` (and `C:\KARIM\osra-backups\`) are the belt to that braces.

**Counts on 2026-10-17:** 43 remote branches — **40 merged** (39 with a PR, 1 predating the workflow) and
**3 not merged**. Recommendation: delete the 40, keep the 3.

## Delete after the go (40)

| Branch | PR | Evidence |
|---|---|---|
| `ANTIGRAVITY` | — | merged into `main` (predates the PR workflow) |
| `chore/p0-repo-hygiene` | #49 | closed + merged |
| `chore/signing-v1-opt-in` | #74 | closed + merged |
| `ci/probe-integrity-check` | #69 | closed + merged |
| `docs/discussion-log-sync` | #28 | closed + merged |
| `docs/kcl-collab-protocol` | #55 | closed + merged |
| `docs/roadmap-status` | #70 | closed + merged |
| `docs/testing-strategy` | #54 | closed + merged |
| `docs/tr-01-02-closed` | #58 | closed + merged |
| `docs/tr-03-04-closed` | #61 | closed + merged |
| `feat/android-tamper-and-lock` | #76 | closed + merged |
| `feat/backend-command-queue` | #52 | closed + merged |
| `feat/backend-push-email` | #51 | closed + merged |
| `feat/backend-ready-frame-redis-hygiene` | #63 | closed + merged |
| `feat/backend-usage-model` | #64 | closed + merged |
| `feat/content-safety-and-ai-engine` | #26 | closed + merged |
| `feat/parent-app-content-safety` | #41 | closed + merged |
| `fix/43-consent-revocation` | #48 | closed + merged |
| `fix/45-youtube-restricted-mode` | #46 | closed + merged |
| `fix/android-sos-tile-api34` | #73 | closed + merged |
| `fix/ci-green-and-guardrails` | #40 | closed + merged |
| `fix/ci-syntax-and-location-fgs` | #39 | closed + merged |
| `fix/p0-location-resilience` | #21 | closed + merged |
| `fix/p0-security-hardening` | #20 | closed + merged |
| `fix/p1-android-hardening` | #23 | closed + merged |
| `fix/p1-flutter-api-contracts` | #22 | closed + merged |
| `fix/p1-ios-shielding` | #25 | closed + merged |
| `fix/p1-windows-enforcement` | #24 | closed + merged |
| `fix/qa-findings-batch` | #36 | closed + merged |
| `fix/security-targets` | #65 | closed + merged |
| `qa/android-build-fix-33` | #35 | closed + merged |
| `qa/audit-2026-10-11` | #15 | closed + merged |
| `qa/cleanup-orphan-families` | #75 | closed + merged |
| `qa/j7-label` | #77 | closed + merged |
| `qa/probe-integrity-check-2026-10-17` | #68 | closed + merged |
| `qa/review-followup-2026-10-11` | #17 | closed + merged |
| `qa/shared-api-trap-2026-10-17` | #72 | closed + merged |
| `qa/tr01-tr02-verification-2026-10-16` | #60 | closed + merged |
| `qa/tr04-comment-correction` | #62 | closed + merged |
| `qa/tr05-tr06-verification-2026-10-17` | #67 | closed + merged |

## Keep — not merged (3)

| Branch | Ahead of `main` | Why it stays |
|---|---|---|
| `KCL` | 1 | the plan's provenance (`docs/QA/KCL-2026-10-16/`) — the readiness assessment every phase row cites; never merged because it is the *input* to the work, not the work. |
| `feat/android-dns-sinkhole` | 23 | open PR **#78** (TR-14..18). Delete after that merges, never before. |
| `qa/verify-track12-2026-10-12` | 1 | its single commit appends a verification entry for `main@fbdef01`, and `main` already carries the merged variant of that same verification (`docs/QA/DISCUSSION-LOG.md:978`, *"QA Verification of main@fbdef01 (Track 1/2 + P1 Batch)"*) — the content is captured, so this is a stale second copy and I would delete it **with** the batch. |

## The one command block, if the go is given

```bash
# from a clone with origin fetched; --delete removes the remote ref only, never a commit on main
for b in\
  ANTIGRAVITY \
  chore/p0-repo-hygiene \
  chore/signing-v1-opt-in \
  ci/probe-integrity-check \
  docs/discussion-log-sync \
  docs/kcl-collab-protocol \
  docs/roadmap-status \
  docs/testing-strategy \
  docs/tr-01-02-closed \
  docs/tr-03-04-closed \
  feat/android-tamper-and-lock \
  feat/backend-command-queue \
  feat/backend-push-email \
  feat/backend-ready-frame-redis-hygiene \
  feat/backend-usage-model \
  feat/content-safety-and-ai-engine \
  feat/parent-app-content-safety \
  fix/43-consent-revocation \
  fix/45-youtube-restricted-mode \
  fix/android-sos-tile-api34 \
  fix/ci-green-and-guardrails \
  fix/ci-syntax-and-location-fgs \
  fix/p0-location-resilience \
  fix/p0-security-hardening \
  fix/p1-android-hardening \
  fix/p1-flutter-api-contracts \
  fix/p1-ios-shielding \
  fix/p1-windows-enforcement \
  fix/qa-findings-batch \
  fix/security-targets \
  qa/android-build-fix-33 \
  qa/audit-2026-10-11 \
  qa/cleanup-orphan-families \
  qa/j7-label \
  qa/probe-integrity-check-2026-10-17 \
  qa/review-followup-2026-10-11 \
  qa/shared-api-trap-2026-10-17 \
  qa/tr01-tr02-verification-2026-10-16 \
  qa/tr04-comment-correction \
  qa/tr05-tr06-verification-2026-10-17 \
; do git push origin --delete "$b"; done
```

Then update roadmap row 0.5 with the new count (`git branch -r | wc -l`) and the sha that carries this table.

## What was not done

- **No branch was deleted**, and none was renamed: this document is derived from `git branch --merged` and the
  PR API, both read-only. Plan 0.5 and AGENTS.md §6 both put remote-state changes outside a tester's lane.
- `ANTIGRAVITY` has no PR (it predates the workflow) but its tip is an ancestor of `main`. If the team wants to
  keep that historical plan branch, drop that one line and the count becomes 39.
- No claim here rests on a remembered number: the counts come from the commands above on 2026-10-17, and each
  PR was fetched rather than recalled.
