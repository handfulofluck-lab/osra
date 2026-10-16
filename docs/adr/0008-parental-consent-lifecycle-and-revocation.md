# ADR-0008 — Parental Consent Lifecycle, Revocation, and Enforcement

- **Status:** accepted
- **Date:** 2026-10-16
- **Supersedes:** Closes the tracked "Known gap" in [ADR-0002](0002-server-authority-and-consent-gate.md)

## Context

Under COPPA (16 CFR Part 312) and GDPR-K (GDPR Article 8), verifiable parental consent (VPC) is not a one-time static event. A parent has the legal right to revoke or withdraw consent at any time, and consent may expire.

ADR-0002 established that creating a child without verifiable parental consent returns HTTP 428 Precondition Required. However, once created, consent records were never queried on subsequent mutations, `ConsentRecord.revokedAt` and `ConsentRecord.expiresAt` were never checked, and there was no endpoint allowing a parent to withdraw consent (tracked under probe target `J3` / Issue #43).

## Decision

1. **Explicit Revocation Endpoints**:
   - Provide `POST /v1/family/children/:id/consent/revoke` and alias `POST /v1/consent/:childId/revoke` allowing authenticated parents to withdraw consent for their child.
   - Updates active consent records by setting `revokedAt = now()`.
   - Enforces family isolation: parents can only revoke consent for children belonging to their own family (HTTP 403 on foreign children).
2. **Active Consent Gate on Child-Scoped Writes**:
   - Enforce active consent on all child-scoped write paths (`requireConsent` middleware):
     - Rules configuration: `PUT /v1/rules/:childId`, `PATCH /v1/rules/:childId`
     - Device enrollment & pairing: `POST /v1/devices/register`, `POST /v1/devices/pair`, `POST /v1/devices/pair/claim`
     - Remote controls: `POST /v1/controls/children/:childId/pause-internet`, `POST /v1/controls/children/:childId/resume-internet`, `POST /v1/controls/children/:childId/bonus`, `POST /v1/controls/children/:childId/wind-down`
     - Geofencing: `POST /v1/location/geofences`
     - Child profile updates: `PATCH /v1/family/children/:id`
   - If consent is missing, revoked (`revokedAt IS NOT NULL`), expired (`expiresAt <= now()`), or jurisdiction mismatches family region: the request is refused with **HTTP 428 Precondition Required** (`{ error: "parental_consent_required" | "consent_jurisdiction_mismatch", jurisdiction }`).
3. **Re-Granting Consent Restores Authority**:
   - A parent can re-grant consent at any time via `POST /v1/family/children/:id/consent`, creating a fresh active `ConsentRecord` and immediately unblocking child-scoped writes.
4. **GDPR Erasure Exemption**:
   - `DELETE /v1/family/children/:id` (erasure cascade) is deliberately NOT gated on active consent: a parent whose consent was revoked or expired must retain the right to erase all family data (GDPR Article 17).

## Reasoning

- Enforcing active consent across all write paths ensures that the API never accepts ongoing configuration, device enrollment, or surveillance modifications for a child whose consent was withdrawn.
- Status code 428 Precondition Required clearly signals to integrators and client apps that lawful basis preconditions are missing, distinct from authorization failures (401/403) or syntax errors (400).
- Checking `revokedAt === null` and `expiresAt === null || expiresAt > now()` brings the database schema's temporal tracking columns into active policy enforcement.

## Consequences

- **Positive:** Closes the COPPA/GDPR-K regulatory compliance gap.
- **Positive:** Probe target `J3` is promoted to a green acceptance gate check.
- **Positive:** Tested across all child-scoped mutations, including unit tests and live probe.
- **Negative:** Additional database query to check active consent on child write routes (mitigated by indexing and caching active consent when available).

## Evidence

- Middleware: `services/api/src/middleware/requireConsent.ts`
- Routes: `services/api/src/routes/consent.ts`, `services/api/src/routes/family.ts`, `services/api/src/routes/rules.ts`, `services/api/src/routes/devices.ts`, `services/api/src/routes/controls.ts`, `services/api/src/routes/location.ts`
- Tests: `services/api/test/consent.test.ts`, `services/api/scripts/qa-probe.mjs` (J3)
