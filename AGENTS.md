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
| `services/api/scripts/qa-probe.mjs` | Adversarial acceptance gate (must pass before merge) |
| `services/api/scripts/e2e.mjs` | Happy-path acceptance flow |
| `docs/test-guides/` | Tester-facing documentation |
| `docs/SPEC*.md` | Product/API specification |
