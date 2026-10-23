### QA — an authorization matrix for the API, and two probe checks that could not fail (plan 2.7)
- `docs/QA/security/authz-matrix.md` lists every route the API registers (87 in `src/routes/` plus the two
  realtime routes) against eleven callers. The callers are owner, co-parent, guardian, another family's
  parent, own device, sibling device, revoked device, revoked parent session, expired token, wrong-purpose
  token and no token. Each cell is the status the guards at the cited `file:line` should return.
- The HMAC routes have their own table: own, sibling and other-family device secrets, the global secret with
  and without a service caller, a replayed nonce, a stale timestamp and a v1 signature. The auth and MFA-reset
  routes list what each accepts and must refuse.
- **Probe B7 and B9 could not fail (F1).** They called `GET /v1/insights/:childId` and `PUT /v1/digests`, routes
  that were never registered, so the router's 404 satisfied their `[403, 404]` acceptance even with no token.
  They now assert the exact `403 forbidden` on two child-scoped reads that had no cross-family check:
  `GET /v1/content/searches` (B7) and `GET /v1/social/events` (B9). The old names are acknowledged in
  `scripts/probe-gate-acks.json`.
  - Measured on a local stack: probe 169/0.
  - With `requireFamily` removed from `content.ts:266` and `social.ts:166`, both checks fail (`got 200`).
- Four authorization questions were raised. Claude decided them on #329 as findings F2–F4 plus one
  consistency fix:
  - parent-side writes of device-reported data;
  - guardian edits to a child's birth year;
  - parent location pings;
  - `ws-ticket` answering a purpose token with 403.

  The fixes landed in #331. The matrix shows the statuses after that merge, with each changed cell marked
  by its finding.
- **Probe section Q (Q1–Q8): the matrix, column by column.** Each check walks one caller across all 62 JWT
  routes and names every route that answers wrong. The callers are a revoked device, a revoked parent
  session, an expired token, a password-reset token, no token, a guardian and a co-parent with no
  permissions, a device token on parent-only routes, and another family's owner.
  - **Why the probe has to do it:** unit tests can't. Their harness has no global hook, and that hook is the
    only revocation check on most routes.
  - **Measured on a local stack:** 178 passed / 0 failed. With six guards removed, every Q check names its
    route.
  - **Cost:** the probe now takes about 3 minutes instead of about 80 s. The section paces itself on the rate
    limiter's headers.
