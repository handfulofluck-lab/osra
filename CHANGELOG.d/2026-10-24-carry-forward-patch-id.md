### CI — the carry-forward comparison ignores context lines, so a folded merge keeps its signature (#357)
- `verified-gate` refused a correctly folded merge. It decided "the PR's own change is identical" by
  comparing `git patch-id --stable` of `diff(merge-base(main,S), S)` with `diff(merge-base(main,H), H)`,
  and `patch-id` hashes hunks **with their context lines**. Folding main in moves the merge base, so when
  main edited a line inside the PR hunk's context window the context differed while the change did not.
  #349 was stuck on it: default context DIFFER, `-U0` EQUAL, and the same `git diff --stat` both ways.
- The comparison now uses `-U0` on **both** sides, so the result no longer depends on where main is. The
  other two conditions are unchanged: S is an ancestor of H, and every commit in `S..H` that is not on
  main is a merge commit.
- The decision moved out of the workflow into `scripts/verified-gate-carry.mjs`: it prints `carried`,
  `differs` or `cannot-decide`, names the deciding rule on stderr, and exits 0, 1 or 2. The workflow is a
  thin loop over the signed shas, the same split `workflow-lint` already uses for
  `check-verified-gate-signers.mjs`. A non-merge commit after the signature is exit 2 ("cannot decide"),
  which is the outcome the inline bash produced — it printed "non-merge commits since, not carried
  forward" and the job failed.
- `--selftest` builds five fixtures with real `git` in a temporary directory. A moved neighbour carries
  (it differed before the fix); a merge that changes the PR's own hunk still refuses; an empty non-merge
  commit after signing is exit 2; a rewound signed sha is exit 2; and a merge of main's own new file
  carries, with main's file never entering the PR's patch. Disabling any one rule makes its case fail.
  Wired into `workflow-lint` beside the signers self-test.
- What it no longer catches: a pure line move, where the same lines end up at another line number.
  `git range-diff` would catch that, and is a larger change to the gate than this rule needs (#357).
