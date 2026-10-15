# ADR-0004 — Parent session hygiene: rotating refresh tokens, WS tickets, optional MFA

- **Status:** accepted
- **Date:** 2026-09-19
- **Supersedes:** —

## Context

A parent's session is the keys to the whole family's data, and the first implementation was weak in ways
that are easy to miss because nothing *breaks*:

- a single long-lived access JWT (7 days, 10 years for devices) with no way to revoke it;
- the WebSocket connection carried the JWT as a **query parameter**, so it landed in proxy logs;
- refresh tokens lived in memory, so `/logout` was cosmetic and a stolen token could not be invalidated;
- MFA existed as an enrolment endpoint but was never enforced at login.

The product also has to be usable: a parent on a phone must not be logged out constantly, and the child
device must keep reporting without a login.

## Decision

- **Short-lived access tokens + rotating refresh tokens.** A refresh token is single-use; replaying one
  (i.e. using a token that was already rotated) is treated as **theft** and revokes the parent's sessions.
- **Explicit revocation paths:** `/logout`, `/logout-all`, and automatic revocation on password reset and
  on MFA enable.
- **Devices get their own, separately-revocable identity** (ADR-0003) — unpairing revokes the device
  token on every route.
- **WebSockets authenticate with single-use tickets**: `POST /v1/ws-ticket` returns a short-lived ticket;
  the socket connects with `?ticket=`. The legacy `?token=` path is kept for old clients but is not the
  documented route.
- **MFA is optional and off by default**, enforced only when a parent enables it; TOTP replay is rejected
  and fails **closed** in production when Redis (the replay guard) is unavailable.
- **The failure mode is chosen deliberately:** when a dependency is down, authentication fails closed
  (503/401), never open.

## Reasoning

- Rotation plus reuse detection is the cheapest way to get theft detection without a session table: a
  replayed token *is* the signal.
- Tickets keep credentials out of URLs (logs, history, referrers) while preserving the "one connection,
  authenticated once" ergonomics.
- Optional MFA matches the audience: a forced second factor on a parenting app loses more users than it
  protects, but the mechanism must exist for those who want it — and when enabled it must be real
  (`mfa_required`, not a hint).

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Long-lived JWTs only (simplest) | No revocation; a leaked token is valid for its whole lifetime |
| Server-side session table for everything | Correct, but adds a DB round-trip to every request and a new failure mode; Redis-backed token state covers the parts that need revocation |
| One shared device token per family | A compromised device would act for siblings — see ADR-0003 |
| Forced MFA for all parents | Support burden and abandonment risk rated higher than the marginal security gain for a consumer product |

## Consequences

- **Positive:** revocation is real and tested; a replayed refresh token invalidates the family's sessions;
  access tokens are useless in URLs; MFA, when on, is enforced before any data route.
- **Negative:** Redis becomes a login dependency (documented, and the code fails closed rather than open).
- **Known gap (tracked):** access tokens are stateless, so revocation kills *refresh* immediately while an
  already-issued access token stays valid until it expires; the window is 7 days and is why the TTL is
  short. The probe checks `F2`/`F3`/`F4` cover reuse, rotated-session death and logout.
- **Deliberate**: the legacy `?token=` WS path remains for already-deployed clients; removing it is a
  breaking change tracked in the roadmap, and its presence is recorded in the audit rather than hidden.

## Evidence

- `services/api/src/routes/auth.ts` (rotation, reuse detection, logout, MFA enforcement),
  `services/api/src/realtime/gateway.ts` (ticket issue/consume),
  `services/api/src/lib/totp.ts` (replay guard).
- Tests: `services/api/test/auth.test.ts`, `test/token-hygiene.test.ts`; probe `F1`–`F7`.
- Incident: `#2`/`#5` (revocation scope), the review response
  `docs/QA/OSRA-REVIEW-RESPONSE-2026-09-18.md`.
