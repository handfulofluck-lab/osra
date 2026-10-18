# ADR-0025 — Parent session revocation is a counter, not a clock

- **Status:** accepted
- **Date:** 2026-10-18
- **Deciders:** Kimi Code (development lead), implementing #117 (finding by Claude); #110/#111 are the
  probe history that hid it
- **Related:** ADR-0014 (sessions, `iat < epoch`), #110, #111, #117

## Context

ADR-0014 §4 revokes every live parent access token by writing
`auth:invalid-before:<parentId>` = `Math.floor(Date.now() / 1000)` and rejecting a token when
`iat < epoch` (`services/api/src/lib/sessions.ts`). `iat` has one-second resolution.

Two consequences:

1. **A token minted in the same second as the revocation survives.** It has `iat == epoch`, and `<`
   accepts it for its full 7-day life. In the ADR-0014 theft response, an attacker who refreshed (or
   logged in) in that second keeps a working session after the response meant to kill it (#117).
   The #110 probe symptom was the same defect seen from the other end — the old token survived, and
   the "fresh login" wait added in #111 only avoided one ordering of the flake; it changed no server
   code.
2. **`iat` is written by the minting instance and the epoch by the revoking one.** Any timestamp
   comparison therefore assumes their clocks agree to better than a second. NTP normally holds that,
   but a VM or container can drift, and a revocation must not depend on it.

## Decision

Revocation is a monotonic per-parent counter in the shared Redis.

1. Every token minted by `signParentToken` carries `sv`, the value of
   `auth:session-version:<parentId>` read at mint time (`0` when the key is absent).
2. `invalidateSessionsBefore` increments that counter (`INCRBY … 1`). Password reset, MFA enable,
   logout-all, invite accept and the refresh-reuse/theft response all reach it through
   `revokeAllRefreshTokens`.
3. `isParentSessionLive` refuses `sv < current` and otherwise admits the token. No `Date.now()`
   participates in the decision.
4. The counter key has **no TTL** on purpose: expiring it while a token minted at a higher version is
   still valid would make that token look current again — a resurrection. One small integer per parent
   that ever revoked is cheaper than that failure mode.
5. **Legacy tokens.** A token with no `sv` (minted before this change) is judged by the epoch, now
   **inclusive** (`iat <= epoch`), so the revocation second is covered there too; revocation still
   writes the epoch for that cohort. The branch can be removed one token lifetime (7 days; the key's
   TTL is 8) after the last pre-#117 instance is gone.
6. `/logout` keeps the per-token `jti` revocation; the counter is parent-wide.

## Alternatives rejected

- **Inclusive epoch** (`iat <= epoch`, with `iat = max(now, epoch + 1)` at mint so a legitimate login
  in the revocation second is not killed). The smallest diff, and it closes #117, but it stays
  wall-clock-bound: if the revoking instance's clock lags the minting instance's by ≥1 s, a token
  minted around the revocation still has `iat > epoch` and survives. It also adds an epoch read and a
  clock adjustment to every mint. Rejected as the primary mechanism; retained only as the migration
  path for tokens that carry no counter.
- **Millisecond `iat`/epoch** (the issue's option 3). Finer, still a clock, and it redefines a
  standard JWT claim; the counter is exact rather than merely more precise.
- **A per-parent set of `jti`s** to revoke. Unbounded storage and O(n) checks; the counter is one
  integer.

## Costs and consequences

- One `GET auth:session-version:<parentId>` per mint (login, register, refresh, invite accept) — small
  next to the refresh-token writes those paths already do.
- One `INCRBY` per parent-wide revocation, plus one integer key per parent that has ever revoked. The
  legacy epoch write remains during the migration.
- Verification is still one `GET` for an `sv` token (the version instead of the epoch); legacy tokens
  read the epoch instead.
- **Race semantics.** A login whose version read lands before a concurrent revocation is born stale
  and dies immediately — the conservative direction; logging in again works. A refresh already in
  flight can read the post-revocation version and mint a token that lives; by construction that token
  was minted after the revocation, which is not the #117 window. Closing that would require an atomic
  check-and-mint against the counter and is out of scope here.
- **Rolling deploy.** A revocation performed by a not-yet-upgraded instance writes only the epoch,
  which `sv` tokens ignore. Deploy every instance (today there is one) before relying on the
  guarantee; a single-instance restart has no mixed-version window.
- The legacy epoch branch and its key can be deleted 8 days after the last pre-#117 instance is
  retired; ADR-0014 §4's `iat < epoch` sentence is superseded by this ADR for the counter-bearing
  tokens.
