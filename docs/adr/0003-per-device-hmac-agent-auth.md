# ADR-0003 — Agents authenticate with per-device HMAC secrets

- **Status:** accepted
- **Date:** 2026-09-19
- **Supersedes:** the original "one shared `INTERNAL_HMAC_SECRET` shipped in every client" design

## Context

Child agents must be able to report things the parent must trust: "accessibility was disabled",
"a VPN was connected", "a concerning search happened". These reports arrive over the same public API as
everything else, and the parent app renders them as facts. So the server needs to know **which device**
spoke, and an attacker must not be able to forge a report.

The first implementation used one global `INTERNAL_HMAC_SECRET`, shipped inside the Android APK, the
Windows agent and the test launcher. Consequences observed in review:

- Anyone who extracted the secret from any APK could sign reports for **any** child.
- Rotating it would break every deployed agent at once.
- It made the "the alert is genuine" claim meaningless — the security property the product sells.

Constraints: agents cannot rely on a user-facing login flow (the child must not have to authenticate),
and the pairing ceremony (a 6-digit code minted by the parent) already exists and is the natural place
to hand out identity.

## Decision

- At pairing, the server mints a **per-device secret** (`Device.internalSecret`, 32 random bytes) and
  returns it **once** in the claim response; the agent stores it (Android DataStore, Windows
  `agent.config.json`, iOS app group).
- Agent → server calls under `/internal` are signed `HMAC-SHA256(secret, body)` in
  `X-FamilyShield-Signature`, verified in constant time against **that device's** secret, resolved from
  the request (`x-device-id`, the body `deviceId`, or — for the iOS reporter shape — the body `childId`).
- The signature proves *which device* spoke; the route then asserts the payload is about that device's
  own child (this second step is what `#29` fixed for the content routes).
- The global `INTERNAL_HMAC_SECRET` survives **only** as the AI-engine fallback, so the engine can post
  server-side classifications without being a paired device.
- Device tokens are revoked on unpair (`revoked:device:<id>`), and the check runs app-wide.

## Reasoning

- Per-device secrets make the alert's authenticity *local*: compromising one device's secret affects one
  device, and rotation is per device.
- Signing the body (not headers/method) kept the agents simple and is sufficient **once** the route
  also asserts `childId` ownership — the identity and the claim are two separate checks, deliberately.
- Constant-time comparison and failing closed when no secret resolves keep the verification honest.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Keep one global secret (rotate often) | Any extracted APK breaks the whole fleet; rotation is a flag day; authenticity is unprovable |
| Mutual TLS with client certificates | Operationally heavy for consumer installs; certificate pinning + rotation on mobile is brittle |
| Require a parent login on the child device | Defeats "set it up once"; a child who knows the parent's credentials could sign their own reports |
| Signed JWT per device only (no HMAC) | A bearer token lets a captured request be replayed by anyone holding it; HMAC at least ties the payload to a key |

## Consequences

- **Positive:** device identity is verifiable and revocable; the probe asserts that a device cannot read
  or write for a sibling, that the global secret fails against a device holding its own secret, and that
  revocation holds on every route.
- **Negative:** the secret lives on the device (Android DataStore, Windows plaintext config, iOS app
  group) — a device-local attacker can read it. Hardening to Keychain/DPAPI is tracked in the audits.
- **Known gaps (tracked, not hidden):** the signature covers only the body, so an identical signed
  request can be **replayed** (probe target `J2` — needs a timestamp/nonce); and the global-secret
  fallback still authenticates devices created through the parent `POST /v1/devices/register` path, which
  no shipped client uses (probe target `J6` / ask 16).
- **Consequence for tests:** agents created by tests without a per-device secret exercise the fallback,
  so the fallback's scope must stay visible — hence `J6` is a tracked target rather than silently green.

## Evidence

- `services/api/src/lib/internalAuth.ts` (resolution + constant-time verify),
  `services/api/src/routes/devices.ts` (claim mints the secret, revocation on unpair),
  `services/api/src/server.ts` (app-wide revocation hook).
- Probe checks: `G1`–`G12` (identity, sibling access, revocation), `J5` (global secret must fail against
  a device holding its own), `J6` (fallback scope, tracked), `E1`–`E5` (signature/acceptance).
- Incident history: `#1` (secret leakage via parent payloads), `#4` (cross-child injection), `#29`
  (the same class in the new content routes), `#2` (the iOS reporter's payload shape).
