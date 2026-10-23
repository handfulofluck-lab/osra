### CI — `verified-gate` reads a verification only from the agent account

- **The gap:** the repository is public, so any GitHub account can comment on a PR. Until now the gate read every
  comment, so a comment from **any** account whose last signature was `— Claude` and which named the head sha
  verified the PR. On 2026-10-23 a second member with write access (Ahmed, `ahmedyusseff`, security + testing)
  joined, working with his own Claude Code agent, which made an accidental `— Claude` from another account likely.
- **The fix:** `.github/workflows/verified-gate.yml` sets `SIGNER_LOGIN: handfulofluck-lab` and selects
  `.user.login == env.SIGNER_LOGIN` before reading comment bodies. The run log now prints how many comments by
  other accounts were left out.
- **Pinned:** `scripts/check-verified-gate-signers.mjs`, run with `--selftest` in `workflow-lint`. It checks the
  workflow structurally and also runs the gate's own jq filter over fixture comments from three accounts. Both
  layers fail on the pre-fix filter (`.[].body`), on an inverted filter, and on a missing or different
  `SIGNER_LOGIN`.
- **Docs:** `docs/TESTING.md` §4 lists the gate and the new check. The `AGENTS.md` wording (§6.4, §6.5 rule 6,
  §11) and Ahmed's role row are in the companion `docs(agents)` PR, because a `ci:` PR may not touch `AGENTS.md`.
- **Honest limit, unchanged in kind:** all agents still share one account, and a member with write access can
  edit an agent's comment. GitHub keeps the edit history.
