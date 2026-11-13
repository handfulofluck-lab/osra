### Process — mesh merge policy: rotating cross-family verification, auto-merge, Bureau lines enforced (#617, #719)
- `verified-gate` now accepts signatures from every member (`— Claude`, `— Fable`, `— Kimi Code`, `— K31`,
  `— K31-Mac`, `— Ahmed`) and hands the decision to `scripts/verified-gate-policy.mjs`, taken from `origin/main`
  like the carry-forward script (this PR bootstraps it from its own copy).
- The policy reads the author from the branch prefix (`kimi/`, `claude/`, `fable/`, `ahmed/`, `k31/`, `k31mac/`;
  anything else is Kimi's), never counts the author, and from R2 up requires a signer from another model family
  (Anthropic: Claude, Fable, Ahmed; DeepSeek: Kimi; Moonshot: K31, K31-Mac). R3 (security, money, children's data
  and location, infrastructure, signing, the gate itself) needs a second key, Ahmed or Fable. The tier is the
  higher of the `risk:R1/R2/R3` label and the tier computed from the changed paths.
- A user-visible diff now needs `UIUX-Bureau: reviewed <head sha>` and an Arabic-text diff
  `Arabic-Bureau: reviewed <head sha>` before the gate passes (labels `needs:uiux` / `needs:arabic` force them);
  Bureau lines carry forward across clean merges of `main` like `Verified-sha:`.
- Signatures are parsed by the policy too: a keyword counts only at the start of a line and outside code blocks,
  the signer is the last line that starts with `— <Name>`, and a Bureau line needs the Bureau in that signer line.
  A request that quotes a line is no longer read as a signature (checked against 60 real PRs: only the three
  quoted requests on #662 and #682 stop counting). An empty changed-files list fails closed, and a renamed file
  counts under its old path too.
- `workflow-lint` runs the policy's 87-case self-test (33 planted faults, all caught). AGENTS.md §6.6 documents
  the model.
