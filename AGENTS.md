# AGENTS.md — working agreement for AI agents in this repository

> Read this first. It is binding for every agent (Antigravity, Kimi Code, Copilot, Cursor, …)
> that touches this repo.

## 1. Roles

| Agent | Role | May do | Must not do |
|---|---|---|---|
| **Kimi Code** (QA / verification) | Tests, adversarial probing, audits, regression gates, release verification | Read everything, run suites, write `docs/QA/**`, `scripts/qa-probe.mjs`, file issues, report findings | Ship product fixes; change application behaviour |
| **Antigravity** (implementation) | Fixes findings, builds features, refactors | Edit application code + tests, rebuild artifacts | Weaken or delete a failing QA check to make it pass; edit `docs/QA/audits/**` |
| Human maintainer | Decides product/security trade-offs, publish/release | Everything | — |

The split exists so the author of a change is never the only verifier of it.

## 2. The loop

1. **Kimi** runs the gates, audits and probes; publishes findings as
   `docs/QA/ANTIGRAVITY-INBOX.md` entries + GitHub issues with severity labels.
2. **Antigravity** picks the highest-priority open item, implements the fix **on a branch**,
   and must satisfy the item's *Acceptance* line (normally: the named `qa-probe` checks pass).
3. **Antigravity** runs the full local gate before requesting review (see §3) and records the
   result in the PR description.
4. **Kimi** re-runs the gates on the branch, verifies the specific claim (not just "tests pass"),
   and moves the item to *Verified* or returns it with the failing evidence.
5. Human merges. Kimi updates `docs/QA/QA-REPORT-*.md` status.

## 3. Definition of done (every change)

- [ ] `services/api`: `pnpm --filter @familyshield/api test` green (193+ tests).
- [ ] `services/api`: `node scripts/qa-probe.mjs` green against a live stack — **no regressions,
      and the acceptance checks for your item now pass** (env: `INTERNAL_HMAC_SECRET`).
- [ ] `services/api`: `node scripts/e2e.mjs` still 50/50 against a live stack.
- [ ] Client suites green for the platform you touched:
      `apps/parent-app` → `flutter test` · `apps/child-android` → `./gradlew testDebugUnitTest`
      (`ANDROID_HOME` required) · `apps/agent-desktop` → `dotnet test` ·
      `services/ai-engine` → `pytest tests`.
- [ ] New/changed behaviour has a test in the same suite that failed before the fix.
- [ ] Docs touched by the change are updated (`docs/`, `docs/test-guides/`, this file if the
      workflow changes).

## 4. Hard rules

- **Never** weaken a check, delete a failing assertion, or add a skip to make a gate green.
  If a check is wrong, say so with evidence and let the human decide.
- **Never** commit secrets, tokens, keystores, or built binaries (`dist/` is gitignored on
  purpose). Config examples use placeholders only.
- **Never** rewrite working code that a QA report marks "Verified solid" without a reason in
  the PR description.
- Preserve the security invariants: family isolation (403), consent gate (428), per-device HMAC
  agent auth, device revocation on unpair, refresh rotation, optional MFA.
- Findings are evidence-based: file:line + repro + expected/actual. "Seems risky" is not a bug.

## 5. Where things live

| Path | Purpose |
|---|---|
| `docs/QA/QA-REPORT-<date>.md` | Consolidated QA state (Kimi-owned) |
| `docs/QA/audits/*.md` | Raw per-platform audits (read-only, Kimi-owned) |
| `docs/QA/ANTIGRAVITY-INBOX.md` | The ordered work queue (Kimi writes, Antigravity works through) |
| `docs/QA/DISCUSSION-LOG.md` | The durable, full-detail dialogue between the agents (append-only) |
| `services/api/scripts/qa-probe.mjs` | Adversarial acceptance gate (must pass before merge) |
| `services/api/scripts/e2e.mjs` | Happy-path acceptance flow |
| `docs/test-guides/` | Tester-facing documentation |
| `docs/SPEC*.md` | Product/API specification |

## 6. Landing changes — `main` is protected, no direct pushes

**Every change reaches `main` through a pull request**, including docs, QA reports and one-line
fixes. Nobody (agent or human) pushes to `main` directly. This exists so the author of a change is
never the one who decides it is correct.

**Branch names:** `qa/<topic>-<date>` (Kimi) · `fix/<item-id>-<topic>` or `feat/<topic>` (Antigravity).

### 6.1 A PR is a discussion, not an announcement

Fill in `.github/PULL_REQUEST_TEMPLATE.md`. It requires, in order:

1. **Restatement of the requirement in the author's own words** — "I understand the ask as: …".
   *This is the single most valuable line in the PR*: misunderstandings get caught before code is
   written, not after. If the restatement is wrong, stop and re-discuss instead of reviewing the diff.
2. What changed and why, with `file:line` references.
3. **The exact gates you ran and their raw output** (`qa-probe`, `e2e`, the platform suites).
4. **What the reviewer must verify**, written as falsifiable claims ("check X returns 401",
   "run Y and confirm Z"), not as "looks good".
5. Open questions, assumptions made, and anything deliberately left undone.

### 6.2 Reviewing: point by point, in full detail

The reviewer replies to **every** numbered claim in the PR — quoting the claim and stating
agree / disagree / needs evidence, with the evidence. Vague approvals ("LGTM") are not reviews.
Both agents append their exchange to `docs/QA/DISCUSSION-LOG.md` using its entry format, so the
reasoning survives and can be re-read later. Assume the other agent has *not* seen your screen,
your terminal or your reasoning: write what you saw, verbatim where it matters.

### 6.3 Disagreement and escalation

- One exchange of evidence-backed disagreement is mandatory before concluding either way.
- If both agents still disagree, add the `needs-human` label and stop; the human decides.
- Never merge over an unresolved objection. Never re-open a settled decision without new evidence —
  cite the decision (date + where it was recorded) instead.

### 6.4 Enforcement (and its honest limits)

GitHub branch protection is **unavailable on private repos on the free plan** — the API returns
`403 Upgrade to GitHub Pro or make this repository public to enable this feature`. So the rule is
enforced by the combination below. **Read the install note: two ways of installing the hook look
correct and silently do nothing.**

| Mechanism | What it does | Limit |
|---|---|---|
| `scripts/install-git-hooks.sh` → copies `.githooks/*` into `.git/hooks/` | Refuses a push whose destination is `refs/heads/main` | Per clone; must be run once. Verified working (see below) |
| `.githooks/pre-push` + `git config core.hooksPath <ABSOLUTE path>` | Same, driven from the versioned file | The path **must be absolute** — a relative `core.hooksPath` silently resolves to nothing on Git for Windows. Also, the file only exists in checkouts that contain it (i.e. not on `main` before this PR merges) |
| `.github/workflows/main-guard.yml` | Server-side: on every push to `main`, asserts an associated PR exists; fails the run and files a `needs-human` issue otherwise | Detection, not prevention; only active once merged to `main` |
| This file + PR review | The real control | Relies on both agents honouring it |

**Install (recommended, works regardless of which branch is checked out):**

```bash
scripts/install-git-hooks.sh          # copies .githooks/* into .git/hooks/ and chmod +x
git config --unset core.hooksPath     # make sure no stale/relative hooksPath overrides it
```

**Verified 2026-10-11** (recorded in `docs/QA/DISCUSSION-LOG.md`): with the hook in `.git/hooks/`,
a push to `main` prints `BLOCKED: direct push to main is disabled (AGENTS.md §6 — main is PR-only)`
and exits 1; a branch push exits 0. Two earlier attempts *looked* installed but did nothing — a
relative `core.hooksPath`, and the file being absent from the checked-out ref. Both are documented
above so nobody repeats them.

**For hard enforcement** the maintainer picks one: make the repository public (free protection), or
upgrade to GitHub Pro. That is the human's call.

Maintainer override (deliberate, rare): `OSRA_ALLOW_MAIN_PUSH=1 git push <remote> main`.

### 6.5 Merge rules

A PR may merge only when: the discussion is fully answered, the gates in §3 are green **on the
branch**, and the PR restatement matches what was actually built. Merging is not approval of the
other agent's competence — it is a claim that the evidence in the PR justifies the change.
