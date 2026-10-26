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

## Amendment — 2026-10-18: enrollment is inside the `devices` permission (issue #138)

Decision 5 enumerated the `devices` surface as "(command, unpair)". That enumeration was incomplete,
not a deliberate exclusion: `POST /v1/devices/register` creates a Device row and `POST /v1/devices/pair`
mints a code that the unauthenticated `/pair/claim` exchanges for a device JWT and a per-device HMAC
secret — both *issue signing credentials*, which is at least the authority of commanding an existing
device. An invite defaults to `permissions: []` (`routes/invites.ts:15`,
`prisma/schema.prisma:46,212`), so a guardian with no permissions could mint credentials while the same
guardian got `403 permission_required` on `command` and `unpair`.

**Decision (applied in #138), superseding the parenthetical in decision 5:**

- `POST /v1/devices/register` and `POST /v1/devices/pair` compose
  `[requireParent, requirePermission("devices")]`, exactly like `/:id/command`, `/:id/push-token` and
  `DELETE /:id`. Owners pass implicitly; a co-parent or guardian needs `devices` in the invite.
- Reads stay ungated (decision 5: reads are never gated by permissions).
- `POST /v1/devices/register` returns `sanitizeDevice(device)`. The raw Prisma row exposed the
  `internalSecret` field — the per-device HMAC key column, null at enrollment, minted at claim — and
  any `pushToken` sent in the body. Enrollment has no reason to return either.
- `/pair/claim` is unchanged: it is the credential exchange, it runs before any credentials exist, and
  it must return the secret once to the new device. Its authority comes from the authenticated `/pair`.

**Reasoning.** The permission boundary follows authority, not the HTTP verb. Issuing a credential is
at least as sensitive as using it; leaving enrollment open made `permissions: []` mean "cannot command
the device, but can create the signer that raises its alerts".

**Alternative rejected:** keep enrollment open and document why. No product reason supports a guardian
who may not command a device being able to mint its signing key, and an inviter reading an empty
permission set would be misled about what the invitee can do.

**Cost:** a co-parent or guardian who genuinely needs to add a device must be invited with `devices`
(or invited again). Owners are unaffected. The parent app surfaces the server's `403` in the pairing
dialog; `e2e.mjs` and `qa-probe.mjs` call both routes with owner tokens, and the Android/iOS/Windows
agents only call the unauthenticated `/pair/claim`.

## Amendment 2026-10-26 — a guardian reads a child's alerts, places and activity only with the permission

**Decided by Karim on 26 Oct, 11:43Z** ("Gate by permission", the decision card in the team thread), from
Ahmed's #394 advisory on #326. This supersedes "reads are never gated by this" in decision 5 for **guardians
only**. Owners and co-parents are unchanged.

**Context.** A guardian is an adult the owner invites, such as a grandparent or a babysitter. Until now
`permissions` limited only what a guardian could change. A guardian invited with none could still read every
alert, the family's geofences (home, school), the child's location history and the child's search and social
activity. A babysitter rarely needs any of that, and least access is the safer default before real families
join.

**Decision.**

1. For a parent whose `familyRole` is `guardian`, these reads need the named permission. Without it they
   answer `403 permission_required` with `{ permission }`, the same body `requirePermission` already sends:

   | Permission | Reads |
   |---|---|
   | `alerts` | `GET /v1/alerts`, and anything else that returns alert rows or alert text |
   | `location` | `GET /v1/location/:childId/latest`, `GET /v1/location/:childId/history`, `GET /v1/location/geofences/:childId` |
   | `social` | `GET /v1/social/events`, `GET /v1/content/searches`, `GET /v1/reports/web`, `GET /v1/reports/activity` (the raw rows: URLs, app use, calls and SMS) |

2. **Embedded copies follow the same rule.** `GET /v1/family/me` omits `geofences` for a guardian without
   `location`. Any other response that embeds alert rows or alert text omits them for a guardian without
   `alerts`. `GET /v1/devices/:id` returns the stored telemetry through an allowlist of `TelemetrySchema`'s
   named fields (no passthrough field reaches any reader), and omits `urls` for a guardian without `social`.
   A guardian must never get through a broad read what the narrow read refuses.
3. **Pushes and live events follow the same rule.** The parent push fan-out (#360) skips a guardian's tokens
   without `alerts`. The realtime `alert` and `location` events skip a guardian without `alerts` or `location`
   respectively.
4. **Device tokens are unaffected.** The location reads stay open to the child's own device
   (`deviceAccess: "own-child"`). The gate applies only to parent tokens.
5. **Aggregates stay open.** Usage, summary and wellbeing reports are counts and minutes, so they stay readable
   by every family adult. One exception: `GET /v1/reports/summary` omits `topBlockedDomains` for a guardian
   without `social`, because domain names are browsing content, and `GET /v1/reports/web?blocked=true` already
   refuses them. The visit, call, SMS and concern counts stay. If a report starts to embed alert text,
   coordinates, searches or URLs, decision 2 applies to it.
6. **The family export is owner-only** (decided on #326 the same day). It is the data-rights request, and it
   sits with consent revoke and child delete.
7. **The parent app says why.** On `403 permission_required` for a read, the screen shows that the owner can
   grant access (English and Arabic), never a generic error.

**Why `social` for search, social and web history.** Karim's card named alerts and places. Searches, social
events and browsing history are the content that alerts are made from, so leaving them open would make the
`alerts` gate cosmetic. The invite already has a `social` permission, so no new permission is needed.

**Cost.** A guardian who should see these must be invited with the permission (or invited again). No real family
exists yet, so no stored invite needs migrating.

**Proof owed by the implementation (Kimi; probe and matrix by Ahmed):**

- a unit test per gated read: an owner gets 200, a co-parent with no permissions gets 200, a guardian with the
  permission gets 200, and a guardian without it gets `403 permission_required`;
- `GET /v1/family/me` for a guardian without `location` has no `geofences` key;
- `GET /v1/devices/:id` drops a planted unknown telemetry field for every reader and `urls` for a guardian
  without `social`, and `GET /v1/reports/summary` has no `topBlockedDomains` for that guardian;
- a push fan-out test where a guardian without `alerts` receives nothing;
- probe Q6c keeps only the reads that stay open for a guardian, a new refusal row walks the gated reads, and
  the matrix's guardian column changes to match.
