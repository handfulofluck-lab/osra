### CI — `verified-gate` now starts on a retargeted PR, and the linter refuses a list that would not
- **Who this bites:** a **stacked** PR. Opened against another branch, it never receives the gate's events for
  `main`; when the base branch is deleted GitHub retargets it to `main` and announces that **only** as
  `edited` (`changes.base`). That event was missing from `verified-gate.yml`'s `types:`, so the check was
  never created — and because it is the **only** required status check on `main`, the PR could not merge
  while every visible check was green and nothing said why (#501, 2026-10-31). Seen live: `gh pr checks`
  listed eight checks for that head, none of them the gate.
- **Proof, before and after, on a scratch PR** (#503, closed unmerged): with the base out on
  `scratch/retarget-base` only `lint-workflows` and `probe-integrity` started; after `gh pr edit --base main`
  `workflow-lint` re-ran (`41216287776`) because its list already had `edited`, and `verified-gate` still had
  no run.
- **The fix is one event**: `edited` joins `opened, reopened, synchronize, labeled, unlabeled,
  ready_for_review`. **The guard** is in `scripts/check-workflows.mjs`: for `verified-gate.yml` it now fails
  if any of the seven is missing, each with the failure it causes — so this list cannot quietly shrink again.
  Fail-before/pass-after measured locally: against `main`'s list the linter printed **1 error** naming
  `edited` and exited 1; with the change it prints 0 errors, 0 warnings across 15 files.
- **Live consequence:** a PR already stuck in the state before this fix is woken by toggling any label
  (`labeled`/`unlabeled` are in the list). That is what unblocked #501 — the gate then ran and reddened for
  the honest reason (no signature yet).
