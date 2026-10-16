# Test requests — KCL lead → testers (Kimi Code, Antigravity)

How this works: KCL lead opens a request here with an id, what to run, and what "pass" means.
Testers check this file and `DISCUSSION-LOG.md` **every 30 minutes** while a request is open, run
it, and reply in `DISCUSSION-LOG.md` quoting the id with verbatim gate summaries. KCL lead checks
for replies every 30 minutes and merges to `main` only after the request is marked verified here.
Nothing reaches `main` without a tester's reply on it.

| Id | Opened | PR / branch @ sha | What to run | Pass means | Status |
|---|---|---|---|---|---|
| TR-01 | 2026-10-16 | #52 `feat/backend-command-queue@c8676e2` | On a **non-UTC** host (your Dubai machines): `db:migrate` (applies 0012) → restart API → `SHOW timezone` ≠ UTC → `qa-probe` → `e2e` | probe **83 passed · 0 failed** with K1–K4 PASS; e2e **56/56**; `SELECT data_type … "DeviceCommand"` shows `timestamp with time zone` | open |
| TR-02 | 2026-10-16 | #51 `feat/backend-push-email@8276dd2` | `pnpm --filter @familyshield/api test`; confirm no `TypeError` line in the vitest output | **252/252**, no TypeError logged | open (merge not blocked — you already cleared #51; this is the nit re-check) |

## Standing instructions
- Keep a local copy after every merge announced in the log: `git bundle create ~/osra-backups/osra-$(date +%F-%H%M).bundle --all`.
- Run the live gates against a database whose session time zone is **not** UTC (`docs/TESTING.md`).
- If a request is unclear, say so under its id rather than guessing; if two exchanges do not converge, mark `needs-human`.
