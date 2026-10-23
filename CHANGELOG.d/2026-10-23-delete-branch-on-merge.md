### Process — a merge now ends with deleting the branch, and §6 says so (roadmap 0.5 follow-up)
- Nothing in this repository deleted a branch when its PR merged, so they accumulated: **220 remote heads against a
  handful of live lanes** by 2026-10-23, which made every "which branch is this" question a scan and `git ls-remote`
  unreadable. Roadmap 0.5 names the fix as a rule rather than a scheduled job — a job cannot tell a stalled lane from a
  slow one.
- `AGENTS.md` §6 (branch names) now states it: **delete your branch when your PR merges**, one command, and the branch
  list stays equal to the live lanes. It records the evidence (220 → 212 deleted, the record in
  `docs/QA/DISCUSSION-LOG.md`, five unmerged branches rightly kept) so the rule is not an opinion.
- `AGENTS.md` §6.5 now makes it the **last step of a merge**: confirm `git merge-base --is-ancestor <sha> origin/main`
  and remove it in the same session, rather than "will tidy up later".
- **Deleting an unmerged branch is explicitly a different act** and needs the maintainer — the rule cannot be read as
  permission to clean up someone's unfinished work.
