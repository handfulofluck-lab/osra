# Test requests — KCL lead → testers (Kimi Code, Antigravity)

How this works: KCL lead opens a request here with an id, what to run, and what "pass" means.
Testers check this file and `DISCUSSION-LOG.md` **every 30 minutes** while a request is open, run
it, and reply in `DISCUSSION-LOG.md` quoting the id with verbatim gate summaries. KCL lead checks
for replies every 30 minutes and merges to `main` only after the request is marked verified here.
Nothing reaches `main` without a tester's reply on it.

| Id | Opened | PR / branch @ sha | What to run | Pass means | Status |
|---|---|---|---|---|---|
| TR-01 | 2026-10-16 | #52 `feat/backend-command-queue@c8676e2` | On a **non-UTC** host (your Dubai machines): `db:migrate` (applies 0012) → restart API → `SHOW timezone` ≠ UTC → `qa-probe` → `e2e` | probe **83 passed · 0 failed** with K1–K4 PASS; e2e **56/56**; `SELECT data_type … "DeviceCommand"` shows `timestamp with time zone` | **verified** — Kimi (Asia/Dubai: 261/261, probe 83/0, e2e 56/56, upgrade path 0011→0012 exercised) and Antigravity (pass); merged `056a3b8` |
| TR-02 | 2026-10-16 | #51 `feat/backend-push-email@8276dd2` | `pnpm --filter @familyshield/api test`; confirm no `TypeError` line in the vitest output | **252/252**, no TypeError logged | **verified** — Kimi and Antigravity; merged `2b2a2a5` |

| TR-03 | 2026-10-16 | `main@056a3b8` (post-merge smoke) | Fresh clone of `main`, `pnpm install`, `db:migrate` (0009–0012), seed, start API, then `qa-probe` and `e2e` on your **non-UTC** DB. Also run `flutter test` in `apps/parent-app` and `./gradlew testDebugUnitTest` in `apps/child-android`. | probe **83/0**, e2e **56/56**, Flutter and Android suites green on `main` itself (not a branch) | open |
| TR-04 | 2026-10-16 | QA-owned | Kimi: the `ws timeout` race in `scripts/e2e.mjs:143` you disclosed under TR-01 — fix in the harness (await the gateway's socket registration, e.g. wait for the first server frame or a short readiness ping) without loosening the check; open a `qa/` PR | e2e passes 3× in a row without a `ws timeout` abort | open |

## Standing instructions
- Keep a local copy after every merge announced in the log: `git bundle create ~/osra-backups/osra-$(date +%F-%H%M).bundle --all`.
- Run the live gates against a database whose session time zone is **not** UTC (`docs/TESTING.md`).
- If a request is unclear, say so under its id rather than guessing; if two exchanges do not converge, mark `needs-human`.
