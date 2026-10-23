### API — the two read routes the parent app needed for a reset (#311)

ADR-0031's API half (#305/#307) had no way for a parent to *read* a request they had made, which
blocked #311 in two places: a requester with no session could not re-read their request after an app
restart, and a co-parent's approval prompt had no way to find a request or name its requester. This
adds exactly the two routes the ADR's 2026-10-23 amendment specifies, and nothing else — no state, no
token, no cancel path, no change to an existing route.

- **`POST /v1/auth/mfa/reset/status`** (`services/api/src/routes/auth.ts`, `resetStatusView` +
  the route) takes `{email, password, requestId}`. A `POST`, not a `GET`, because a password never goes
  in a URL. The front door is `/complete`'s, copied: the route's own 20/min bucket, the same
  `unknownParentPasswordHash()` timing path for an unknown address, `401 invalid_credentials` for a bad
  email **or** password, and one `404 request_not_found` for "no such id" and "someone else's id" alike,
  so it is not an oracle. It returns exactly `{requestId, state, createdAt, emailConfirmedAt,
  mailboxLinkExpiresAt, witnessDeadline, codeExpiresAt, attemptsRemaining, witnessKind, witnessAt,
  windowEndsAt, outcomeAt}` — `codeHash`, the code, `witnessRef`, device ids and any other parent are
  absent because the fields are listed, never spread from the row. `mailboxLinkExpiresAt` =
  `createdAt` + 30 min while `requested`; `witnessDeadline` = `emailConfirmedAt` + 24 h,
  `attemptsRemaining` = 5 − `failedCodeAttempts` and `codeExpiresAt` = the live code's deadline while
  `mailbox_confirmed`; anything that does not apply to the state is `null`. **It writes nothing**: it is
  not a sign-in, so it does not cancel the request (decision 3 makes a successful `/login` the cancel
  signal, which needs the authenticator this parent has lost), and it revokes, acks and touches nothing
  but its own rate-limit bucket.
- **`GET /v1/auth/mfa/reset/pending`** takes a live parent session (`preHandler: requireJwt`) and
  `/approve`'s role gate: a `guardian` is `403 role_not_allowed`, an unauthenticated caller `401`. It
  lists the caller's family's requests in `mailbox_confirmed` or `witness_passed` whose `parentId` is
  not the caller's — not `requested`, because nothing reaches a child device before the mailbox step and
  an approval comes after it — as `{requests: [{requestId, state, requester: {parentId, displayName,
  role}, createdAt, emailConfirmedAt, witnessDeadline, windowEndsAt}]}`. The requester's email is not
  returned; `witnessRef` is not either.
- **Tests:** `services/api/test/mfa-reset.test.ts` gains seven: one per amendment claim (1, 2, 3, 4, 5)
  plus the per-state field map and a parent-witness case. Claim 1's test reads `MfaResetRequest`,
  `DeviceCommand` and the session-version counter before and after a `status` call in all three open
  states and compares them, and also counts every write the reset routes make. Each new test failed
  before the routes existed (7 failing on `404`, the rest of the file 33 passing), and each was
  mutation-checked: cancelling the request on read fails claims 1 and 2, answering `403` instead of
  `404` fails claim 3, dropping the `parentId != caller` filter fails claim 4, and spreading the row
  into the response fails both claim-5 tests.
- **Probe:** `services/api/scripts/qa-probe.mjs` gains `O24`–`O28` (claim 1, 3, 4, 4-refusal, 5), and the
  reset family now also invites a `co-parent` (no second factor, no request of their own): their correct
  credentials ask about the requester's request in `O25`, they are the caller `pending` lists it for in
  `O26`, and the owner's own open request is what shows the caller's request left out. Keeping the
  co-parent without MFA keeps the probe at 20 `/login` calls, `/login`'s per-minute limit (#313 review). Each check names the mutant it kills in the
  comment beside it. `node --check` clean; `scripts/check-probe-integrity.mjs --base origin/main`:
  **5 added, 0 removed or demoted**.
- **Docs:** the ADR amendment is appended verbatim, `docs/SPEC.md` carries both routes with their field
  lists and the "writes nothing" property, `docs/TESTING.md` lists `O24`–`O28`, `docs/ROADMAP.md` row 3.3
  records the change.
- **Not verified here:** no live stack in this environment, so `qa-probe.mjs` and `e2e.mjs` were **not
  run** — `O24`–`O28` are unexercised until a verifier runs them on a stack. The unit suite
  (`pnpm --filter @familyshield/api test`, 510 passed) and `tsc` are green, and that run is the author's,
  not verification.
