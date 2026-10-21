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

## Amendment 2026-10-19 — the refresh path orders the version read before the mint (#158)

- **Context:** the “Race semantics” bullet above said an in-flight refresh could read the
  post-revocation version and mint a token that lives, and called closing it out of scope. Review of
  #156 showed that outcome is the one ADR-0014 exists to prevent: a refresh accepted before a
  password reset / MFA enable / logout-all / theft response could mint a **live** access token with the
  post-revocation `sv`, and the rotated refresh token re-created the session in an index that had just
  been cleared. The window is a DB round trip; the attacker is whoever holds a stolen refresh token.
- **Decision — ordering rule.** The refresh record stores `sv`, the sessions version at issue time
  (`services/api/src/routes/auth.ts`, `issueRefreshToken`). `/token/refresh` reads
  `currentSessionVersion(parentId)` **once**, before it retires the presented token and before the
  `prisma.parent.findUnique` round trip, and:
  1. refuses the request when `stored.sv < current` (both the access and refresh halves: a pre-revocation
     refresh token can never mint again, whatever the interleaving);
  2. passes that same value into `signParentToken` (`opts.sv`) and into the replacement refresh record.

  A revocation that lands after the version read therefore makes the returned credentials **stale**,
  not live: the access token carries the pre-revocation `sv` and `isParentSessionLive` refuses it; the
  refresh record carries the same stale `sv` and its next use is refused. A revocation that landed
  before the read is seen by the comparison. No atomic check-and-mint is needed; the ordering is what
  closes the window.
- **Legacy refresh records (no `sv`).** They are refused (`401 session_revoked`), forcing one
  re-login per parent after the deploy. The alternative — checking their derived issue time against
  the legacy epoch — was rejected: the epoch write is best-effort, expires after 8 days and has
  second resolution, so an unknown version would have to be treated as current, which is the same
  fail-open this amendment removes. One authentication event is the cheaper price.
- **Fail closed on the bump.** `invalidateSessionsBefore` no longer swallows a Redis error from
  `INCRBY auth:session-version:<parentId>`: the caller returns 5xx and the client retries. Reporting a
  successful logout-all / password reset / theft response while every token stays live was the second
  finding (#135’s rule). The legacy epoch `SET` stays best-effort because it cannot keep an `sv` token
  alive.
- **Cost.** The version read moves slightly earlier (it was already one `GET` per refresh mint), plus
  one integer field per refresh record. If the revocation lands after the read, the response still
  returns `200` with credentials that are dead on first use — safe, but the client sees a failed next
  call rather than a failed refresh. Legacy records cost one forced login. A revoked-but-racing
  refresh token remains in Redis until its TTL because the route refuses it without retiring it;
  it can never mint, so this is storage, not security.
- This amendment supersedes the “Race semantics” bullet’s second sentence and the “out of scope”
  conclusion for the refresh path. Everything else in the accepted decision stands.

## Amendment 2026-10-21 — a password-reset link is single-use, and a failed confirm restores it (#167)

- `/reset/request` mints a `jti` and stores `reset:<jti>` → `parentId` and
  `reset:latest:<parentId>` → `jti`, both `EX 900`. `/reset/confirm` consumes `reset:<jti>` with
  `GETDEL` **before** hashing and refuses a missing key — or a `jti` that is not the parent’s latest —
  with `401 invalid_or_expired_token`; a second request therefore kills the first, and two concurrent
  confirmations of one link cannot both win.
- A failure after the consume (hash, password update, or this ADR’s counter bump) restores
  `reset:<jti>` with the token’s own remaining lifetime (`exp − now`), never a fresh 900: that is what
  keeps #162’s 5xx-then-retry contract, since the retry presents the same link. A `200` means the
  password changed **and** `revokeAllRefreshTokens` completed.
- Tokens minted before this change carry no `jti` and no record, so they are refused like a spent
  link: one re-login per parent, the same migration cost accepted above for legacy refresh records.
