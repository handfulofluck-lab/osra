### Merge gate — Codex signs, in his own family and with his own branch prefix (#617, #887)
- `scripts/verified-gate-policy.mjs` knows **Codex** as a signer in the **OpenAI** family, reads a `codex/`
  branch prefix as his, and the `codex/` prefix is in the documented list. Until this lands his
  `Verified-sha` lines do not count, which is why Kimi's second key on #886 was used instead.
- Four self-test rows: a `codex/` branch signed by K31 passes, one signed only by Codex fails, a K31 PR
  signed by Codex passes (different family), and an R3 path with Codex + Ahmed passes (Ahmed as the
  security key). Removing `Codex` from `FAMILY` makes **2 of 288** rows fail.
- `AGENTS.md` §6.6 gains the OpenAI row in the family table and `codex/` in the prefix list; the two
  workflow comments that name the signers say so too.
- Verified: `node scripts/verified-gate-policy.mjs --selftest` → **288 cases pass**;
  `node scripts/check-workflows.mjs --strict` → 0 errors, 0 warnings across 19 workflows.
