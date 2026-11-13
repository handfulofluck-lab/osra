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
- `workflow-lint` runs the policy's 28-case self-test. AGENTS.md §6.6 documents the model.
