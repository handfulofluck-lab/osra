### Merge gate — Ahmed's agent signs as a security key, alongside Fable
- The verified-gate now reads Ahmed's own account, `ahmedyusseff`, for one thing: a `Verified-sha:` signed
  `— Ahmed`. It counts as the R3 security key, as Fable's does (maintainer, 2026-11-13 21:15Z, #617).
- Nothing else from that account counts: no other signer name, no Bureau line. And a `— Ahmed` signature from
  the shared agent account is dropped, so no other agent can sign as Ahmed. A comment from his account counts
  only if it was never edited, because the shared account (an admin) could otherwise rewrite one of his comments
  into a signature; the log says how many of his comments were skipped as edited.
- `scripts/check-verified-gate-signers.mjs` now runs the gate's own read and parse lines over forged and genuine
  comments from three accounts, and its self-test proves twelve broken gates fail in both layers.
