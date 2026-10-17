# ADR-0014 — Internal signing v2 (replay-proof), revocable parent sessions, enforced family roles, secrets at rest

**Status:** Accepted · 2026-10-16 · Phase 2d of the KCL plan (`docs/QA/KCL-2026-10-16/`)

## Context

Five security debts the assessment said a consumer product cannot carry, all tracked as probe
targets or findings since 2026-10-11:

1. **J2 (#42)** — agent requests were signed over the body only. A captured `POST /v1/alerts/internal`
   could be replayed forever and created a new alert each time (probe note E4).
2. **J6 (#44)** — the global `INTERNAL_HMAC_SECRET` fell back to signing for any device that had no
   per-device secret, resolved from the *body's* `childId`; a bare global signature could write into
   any such child.
3. Login/register access tokens had no `jti`; password reset, MFA enable and logout-all revoked the
   refresh tokens but the live 7-day access tokens stayed valid.
4. Invite acceptance minted a JWT with `role: "co-parent"` / `"guardian"`, which `requireParent`
   rejected — co-parents were locked out until they logged in again — and `permissions` were stored
   and never enforced.
5. The TOTP secret was stored in plaintext.

## Decision

1. **Signing v2.** `X-FamilyShield-Timestamp` (unix seconds), `X-FamilyShield-Nonce` (16–128 chars,
   unique per request) and `X-FamilyShield-Signature` = hex HMAC-SHA256(secret, `"<ts>.<nonce>.<body>"`).
   The server rejects `|now − ts| > 300 s` (`stale_timestamp`) and a nonce already seen for the same
   signer within a 600 s window (`replay`, Redis `SET NX`). Every 401 carries a `reason` code.
   **All four signers in the repo** — the API's own test helper, the Android `SignatureInterceptor`,
   the Windows `InternalSigner`, the iOS `InternalSigner` — are pinned to one reference vector
   (`ce725cf9…c220508` for secret `device-secret-1`, ts `1800000000`, nonce `nonce-0123456789abcdef`)
   in their own unit tests, so they cannot drift apart.
2. **v1 is a switch, not a format.** Body-only signatures from a per-device secret are accepted only
   while `INTERNAL_SIGNING_ALLOW_V1=1` — so a fleet can update agent by agent — and the probe reports
   that state as target **J7**; with the switch unset v1 returns `legacy_signature_disabled` and J7
   gates. (Decided here as "on until hardware-verified"; the default flipped to off on 2026-10-17
   after TR-07 verified the Android signer on a device — see the follow-up note below.) The global
   secret is never accepted in v1.
3. **The global secret is a service credential.** It authenticates only in v2 and only with
   `X-FamilyShield-Caller` naming a known service (`INTERNAL_SERVICE_CALLERS`, default `ai-engine`).
   With that header a service may name a child or a device in its body (it is the trusted scorer,
   not an impersonated device); without it the global secret authenticates nothing. A device named in
   a body must otherwise sign with its own secret, and a device with no secret cannot be acted on by a
   body-only signer. J5 and J6 are gating checks; the fallback is gone.
4. **Sessions.** Every parent token carries `jti` and `familyRole`. `revoked:token:<jti>` revokes one
   token; `auth:invalid-before:<parentId>` (unix seconds) is bumped by `revokeAllRefreshTokens`, so
   password reset, MFA enable, logout-all and the theft response kill the live access tokens
   immediately (`iat < epoch` → `401 session_revoked`). `/logout` with a refresh token also revokes
   the access token issued alongside it (`refresh:jwt:<hash>`). Rotation keeps the old-hash → new-jti
   mapping so reuse of a consumed refresh token still kills the session it rotated into.
5. **Roles.** The JWT `role` is always `parent` (it selects the parent surface); the Parent row's
   `role` (`owner` | `co-parent` | `guardian`) travels as `familyRole`. `requireOwner` guards child
   creation, erasure, consent grant/revoke and invites; `requirePermission(p)` guards the mutating
   routes — `rules` (rules write, all controls), `alerts` (ack), `devices` (command, unpair),
   `location` (geofences). Owners hold every permission; reads are never gated by this.
6. **Secrets at rest.** `Parent.mfaSecret` is stored as `enc1:<vault json>` under `VAULT_KEY`
   (`src/lib/secretVault.ts`); a legacy plaintext row still verifies and is re-encrypted at the next
   login. `VAULT_KEY` is required in production (the dev fallback derives from `JWT_SECRET`).

## Reasoning

- A timestamp window alone allows a 5-minute replay; a nonce alone needs unbounded storage. Together
  they bound both: the nonce set lives twice the skew window and nothing older can be valid anyway.
- Binding the nonce to the *signer* (device id, or `service:<caller>`) keeps the keyspace small and
  means a nonce stolen from one device is useless under another secret.
- Making the global secret require a named caller turns an ambient capability into an audited one:
  the log says *who* used it, and the probe can assert that bare use fails.
- The invalid-before epoch is one key per parent instead of enumerating `jti`s, and survives Redis
  restarts for the token lifetime (8-day TTL ≥ 7-day tokens).
- Role in the JWT was a design error: the claim that selects the *surface* (parent vs device) was
  overloaded with the claim that selects *authority* within a family. Two claims, two jobs.
- Encrypting `mfaSecret` with the existing vault primitive costs nothing new and removes the one
  credential a DB dump could use to bypass MFA.

## Alternatives considered

- **HTTP Signatures / AWS-SigV4 style (method + path + headers in the MAC).** Stronger binding, but
  every agent would need a canonicalisation routine; the probe's E5 cross-endpoint check is kept as
  a note, and path binding can be added to the signing string in a v3 without changing headers.
- **Flag day for v2 (no v1 switch).** Would have bricked every paired phone and PC on the testers'
  desks at merge time. The switch is the cost of not doing that; J7 keeps it visible.
- **JWT denylist of every `jti` on logout-all.** Needs the server to know every live `jti`; the epoch
  needs one write.
- **Enforcing permissions on reads too.** Guardians are invited to *see*; the invite's permissions
  describe what they may *change*. Read gating would need a product decision first.

## Consequences

- **Good:** J2 and J6 are gating checks (probe 108/0, one target left — J7); a stolen session dies
  with its parent's action, not a week later; co-parents can use the app; a DB dump no longer yields
  TOTP secrets; the four signers share one test vector.
- **Cost:** two Redis round-trips per signed request (nonce claim) and one per parent request (epoch
  read); agents must keep their clocks within 5 minutes (a device with a wildly wrong clock will see
  `stale_timestamp` — the parent app should surface that); the v1 switch is debt until flipped.
- **Not done:** method/path in the signing string; per-family audit log of who used the service
  secret; UI for permissions (Phase 3). ~~Flipping `INTERNAL_SIGNING_ALLOW_V1=0`~~ — done
  2026-10-17 (follow-up PR to #65): default is now off, `1` opts in, after TR-07's hardware half
  verified the Android v2 signer on a Galaxy Z Flip4; Windows/iOS signers verified by unit tests
  against the shared reference vector.

## Evidence

- Unit: `test/internal-signing.test.ts` (7 — replay, tamper, skew edges, v1 switch, service caller,
  J6, route reason code), `test/sessions-and-roles.test.ts` (7), `test/auth.test.ts` (encrypted
  enrolment); 14 of them fail on `main`. Agent tests: `SignatureInterceptorTest.kt` (+3),
  `InternalSignerTests.cs` (+3), `InternalSignerTests.swift` (+3) — ⚠️ not run here (no Android
  SDK / .NET / Xcode in this sandbox); CI runs the first two, TR-07 asks for all three.
- Live (DB from zero, `Asia/Dubai`): e2e **68/68** (replay → 401 `replay`, bare global → 401, 10-min-old
  timestamp → 401), probe **108 passed · 0 failed · 1 target (J7) · 0 notes** — E4/J2, E4b, E4c, J5,
  J6, J6b, F8, N1–N7 all PASS.
