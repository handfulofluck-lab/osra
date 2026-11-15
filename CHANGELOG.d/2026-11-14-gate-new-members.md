### Merge gate — two new members (#785, #786)
- `scripts/verified-gate-policy.mjs` reads `— Hydrogen` signatures and the `antigravity/` and `hydrogen/` branch
  prefixes (an `antigravity/` branch was read as Kimi's before). Antigravity (Gemini 4 Carbon) and Hydrogen (Gemini 4
  Hydrogen) are two families, so they may verify each other's work; the maintainer prefers another vendor first.
- Antigravity is an R3 security key alongside Ahmed and Fable (maintainer's decision, 2026-11-14 18:01Z). Hydrogen is
  not a security key.
- AGENTS.md §1, §6.6 and §11 carry the new rows; 13 new self-test cases pin each rule.
