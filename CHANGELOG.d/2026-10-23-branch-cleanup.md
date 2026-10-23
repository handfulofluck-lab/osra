### Repository — the merged branches are deleted, with every SHA recorded first (roadmap 0.5)
- The maintainer approved deleting the branches already merged into `main`; the remote held **220 heads** against a
  handful of live lanes, so "which branch is this" cost a scan on every look.
- **Recounted at the moment of deletion** after `git fetch --prune`, and a branch counted as merged only when its tip is
  an ancestor of `origin/main` (`git merge-base --is-ancestor`), never because its PR was closed. Deleted 212, kept 8:
  `main`, the two open-PR heads (#329, #330) and five branches that are **not** fully merged.
- **`docs/QA/DISCUSSION-LOG.md` carries the restoration record**: every deleted branch as `name sha`, beside the kept
  set and the reason each was kept. Any branch can be recreated with `git push origin <sha>:refs/heads/<name>`, which
  matters for the ones whose PR page no longer exists.
