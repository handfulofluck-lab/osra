### Merge gate — an unknown branch prefix fails closed
- `scripts/verified-gate-policy.mjs` no longer reads a branch with no known author prefix as Kimi's. Such a branch now
  fails the gate with a message naming the prefixes, unless it carries a Kimi-authored commit (Kimi's convention
  before 13 Nov). Fable's note on #788: a `gemini/` or `antigravity-fix/` branch must not pass as Kimi's.
- The five unprefixed PRs open on 14 Nov (#615, #646, #657, #679, #702) are listed by exact branch name and keep the
  old reading until they merge; no name may be added.
- New self-test cases: unknown prefixes fail closed, the grandfathered names pass by exact match only, and K31 /
  K31-Mac work signed by Hydrogen counts (cross-family). 284 cases pass.
