### QA — an authorization matrix for the API: skeleton for review (plan 2.7)
- `docs/QA/security/authz-matrix.md` lists every route the API registers (87 in `src/routes/` plus the two
  realtime routes) against ten callers. The callers are owner, co-parent, guardian, another family's parent,
  own device, sibling device, revoked device, expired token, wrong-purpose token and no token. Each cell is
  the status the guards at the cited `file:line` should return.
- The HMAC routes have their own table: own, sibling and other-family device secrets, the global secret with
  and without a service caller, a replayed nonce, a stale timestamp and a v1 signature. The auth and MFA-reset
  routes list what each accepts and must refuse.
- Four open questions, each with the line that raises it. Any parent, even with no permission, can write a
  device's telemetry, activity and app inventory, and file location pings. A guardian can edit a child's
  profile. `/v1/ws-ticket` answers a purpose token with 403 rather than 401.
- **⚠️ Not verified yet:** this is the expected half only. The statuses are read from the code, not observed
  against a stack. Coverage citations and the probe checks for the gaps come in the next push.
- **One finding (F1, not exploitable):** probe checks B7 and B9 call routes that were never registered
  (`GET /v1/insights/:childId`, `PUT /v1/digests`). The router's 404 satisfies their `[403, 404]`
  acceptance even with no token, so they can't fail. Measured on a local stack; the redefinition is
  proposed in the matrix, §5.
