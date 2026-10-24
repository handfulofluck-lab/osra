### CI — the carry-forward comparison ignores context lines, so a folded merge keeps its signature (#357)
- `verified-gate` refused a correctly folded merge. It decided "the PR's own change is identical" by
  comparing `git patch-id --stable` of `diff(merge-base(main,S), S)` with `diff(merge-base(main,H), H)`,
  and `patch-id` hashes hunks **with their context lines**. Folding main in moves the merge base, so when
  main edited a line inside the PR hunk's context window the context differed while the change did not.
  #349 was stuck on it: default context DIFFER, `-U0` EQUAL, and the same `git diff --stat` both ways.
- The comparison now uses `-U0` on **both** sides, so the result no longer depends on where main is.
- Context is ignored, so position is not compared. A merge after the signature must therefore be a clean
  merge of its parents: `git merge-tree --write-tree <p1> <p2>` must reproduce the merge commit's own tree
  exactly. A conflict, a hand resolution, an evil merge that adds something in neither parent, or a merge
  with other than two parents refuses (exit 1) and needs a fresh verification. Re-running merges needs
  git >= 2.38; on an older git the decision is exit 2 rather than silently skipping the rule.
- This closes the gap `-U0` opened: `patch-id` drops the hunk header, including the function name, so a
  hand-edited fold could move the PR's line into another function and the patch would still hash the same.
  The only remaining limit is a line moved by a clean merge, and that is git's own result.
- The decision moved out of the workflow into `scripts/verified-gate-carry.mjs`, run from `origin/main`
  so a merge cannot change the rule that judges it. It prints `carried`, `differs` or `cannot-decide`,
  names the deciding rule on stderr, and exits 0, 1 or 2. The workflow is a thin loop over the signed
  shas, the same split `workflow-lint` already uses for `check-verified-gate-signers.mjs`. S is still an
  ancestor of H, and every commit in `S..H` that is not on main is still a merge commit.
- `--selftest` builds seven fixtures with real `git` in a temporary directory. A moved neighbour carries
  (it differed before the fix); a conflicted resolution, a hand rewrite that moves the PR's line into
  another function (whose `-U0` patch-ids are equal — the gap rule (c) closes), a non-merge commit after
  signing, a rewound signed sha and a three-parent merge all refuse; and a merge of main's own new file
  carries. Disabling a rule makes its case fail. Wired into `workflow-lint` beside the signers self-test.
