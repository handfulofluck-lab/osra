### Repository — hygiene as a standing rule, and verify branches clean themselves up
- `AGENTS.md` §6.0: what may live on `origin` (main, open-PR branches, `site-pages`, `store/*`), how stale
  PRs (7 days asked, 14 days closed) and issues (21 days checked) are handled, where files go, the secret
  file types `.gitignore` refuses, and a weekly sweep reported in the #50 digest. `claude/` and
  `verify/<PR>-<label>` join the branch-name list.
- `.github/workflows/branch-hygiene.yml`: when a PR closes, its `verify/<PR>-*` fault branches are deleted
  (they never have a PR of their own, so `delete_branch_on_merge` missed them: 88 swept by hand on 11 Nov,
  42 more by 12 Nov). *Run workflow* sweeps every closed PR's leftovers. Only `verify/<N>` and
  `verify/<N>-…` refs of closed PRs are touched; each deletion is logged as `name sha` for restore.
