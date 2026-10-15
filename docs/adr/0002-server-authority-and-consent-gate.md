# ADR-0002 — The server is the authority: family isolation (403) and a consent gate (428)

- **Status:** accepted
- **Date:** 2026-09-14
- **Supersedes:** —

## Context

Parental-control software holds the most sensitive data a family produces: where a child is, what they
search for, who they message, and what they are *not* allowed to do. Two failure modes are catastrophic
and different from ordinary bugs:

1. **Cross-family leakage** — one family reading another family's child. Any API route that trusts a
   client-supplied `childId` without checking ownership is a data breach, not a bug.
2. **Monitoring without lawful basis** — COPPA (US) and GDPR-K (EU/UK) require verifiable parental
   consent *before* collection. A product that starts collecting because a request looked valid is
   non-compliant by construction.

Both are hard to bolt on later: retrofitting ownership checks into every route means holding an audit
of every query forever, and retrofitting consent means finding every write path.

## Decision

- **Every family-scoped route resolves the target through its owner.** Middleware
  (`requireFamily({ model, param, source })`) loads the child/device/geofence/alert, compares its
  `familyId` with the authenticated parent's, and returns **403** on mismatch. Routes never trust a
  bare `childId` from the body.
- **Child-scoped writes are gated on a live `ConsentRecord`.** Creating a child without consent returns
  **428 Precondition Required**, and the record carries the method, jurisdiction and expiry.
- **Device identity is separate from parent identity.** A device token may only reach its own device;
  parent-only routes are wrapped in `requireParent`.
- **Agents are not exempt.** Internal (HMAC) routes answer to the same rules: a device's signature
  proves *which* device is speaking, and the route then asserts that the body's `childId` is that
  device's own child (see ADR-0003 and the `#29` fix).

## Reasoning

- A single choke point is auditable: "which routes are family-scoped?" is answerable by grepping for the
  middleware, and the probe suite can enumerate the invariants (cross-family reads and writes for every
  resource type).
- 403 and 428 are *deliberate* status codes: they tell an integrator that the request was understood and
  refused for a policy reason, rather than a generic 400/500 that hides which rule fired.
- Making the server authoritative means the clients cannot weaken the policy: a patched parent app
  cannot read another family's data, and a rogue agent cannot write into another child's timeline.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Ownership checks inside each query (`where: { familyId }`) | Works until someone forgets one — and "forgot one" is exactly how `#29` happened; a middleware choke point fails closed by default |
| Client-side enforcement ("the app only asks for its own children") | Trivially bypassed; the API is public to authenticated clients |
| Consent recorded after first collection, reconciled later | Illegal under COPPA/GDPR-K, and unfixable retroactively for data already collected |
| Return 404 instead of 403 for cross-family access | Hides less information, but makes legitimate misconfiguration indistinguishable from an attack in logs and tests |

## Consequences

- **Positive:** the invariants are *testable* — the probe suite asserts cross-family reads/writes across
  children, devices, rules, geofences, content, reports, insights and digests, and `#29` was caught
  precisely because a new route did not follow the pattern.
- **Positive:** consent is a first-class row, so a jurisdiction/expiry change is a data change, not a
  code change.
- **Negative:** every new route needs the middleware plus a probe check; a route added in a hurry fails
  closed (403/428) which is *safe* but means a missing check shows up as a broken feature in testing.
- **Known gap (tracked, not hidden):** consent *revocation/expiry* is recorded in the data model but not
  yet enforced on every write path, and there is no revoke endpoint — probe target `J3`. Until then,
  treat "consent gate" as covering creation, and see `docs/QA/ANTIGRAVITY-INBOX.md` for the open item.

## Evidence

- Middleware and routes: `services/api/src/middleware/requireFamily.ts`,
  `services/api/src/routes/{family,devices,rules,location,alerts,social,content}.ts`.
- Tests: `services/api/test/*.test.ts` (isolation cases) and the live suite `scripts/e2e.mjs`.
- Adversarial checks: `scripts/qa-probe.mjs` sections `B` (isolation), `C` (consent), `G` (device
  identity/revocation), `I` (categories), `J` (bounds and error hygiene).
- The `#29` incident (a new content route missing the pattern) is documented in `CHANGELOG.md` and
  `docs/QA/audits/AUDIT-API-2026-10-11.md`.
