### Process — automatic head-branch deletion is on, with the rule as its backstop (roadmap 0.5 follow-up)
- **GitHub's *Automatically delete head branches* setting (`delete_branch_on_merge`) is now ON**, so a merge through the
  web UI or the API removes the head branch itself. It had been **off**, which is how the branch list drifted: **220
  remote heads against a handful of live lanes** by 2026-10-23, making every "which branch is this" question a scan and
  `git ls-remote` unreadable. Found by Claude reviewing #335: I had written that nothing deletes a branch on merge, which
  was true of our rules but wrong about the repository's own capability.
- `AGENTS.md` §6 (branch names) now states the rule as a **backstop** rather than the mechanism: the setting does the
  work, and the rule covers a merge made outside GitHub and is how the setting's continued existence gets checked. It keeps the evidence (220 → 212 deleted, the record in
  `docs/QA/DISCUSSION-LOG.md`, five unmerged branches rightly kept) so the reader can check rather than trust.
- `AGENTS.md` §6.5 now makes it the **last step of a merge**: confirm the setting is on and the head branch is gone
  (`gh api … -q .delete_branch_on_merge`, then `ls-remote --heads`), and delete by hand only when the merge happened
  outside GitHub.
- **Deleting an unmerged branch is explicitly a different act** and needs the maintainer — the rule cannot be read as
  permission to clean up someone's unfinished work.
