### Security
- The per-device signing key is now stored encrypted under `VAULT_KEY`, like the parent's two-step secret (ADR-0014). Rows written before this are accepted and re-stored encrypted the next time they verify a request. The device protocol does not change. (osra-security#14, gate #637)
