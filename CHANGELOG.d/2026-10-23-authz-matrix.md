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
- **⚠️ Not verified yet:** apart from the probe checks above, the matrix is the expected half only. The
  statuses are read from the code, not observed against a stack. Coverage citations and the probe checks
  for the gaps come next.
