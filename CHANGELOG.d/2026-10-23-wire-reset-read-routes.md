### Parent app — the reset screens now use the two read routes: resume, names, and honest endings (#297)

Wires `POST /v1/auth/mfa/reset/status` and `GET /v1/auth/mfa/reset/pending` into the screens built in
#311, closing the two gaps that PR's review left open.

- **Restart no longer starts over.** `MfaResetRequestScreen` checks secure storage on open; when a
  saved request exists it hands off to `MfaResetWaitingScreen` in resume mode. That screen asks for the
  password once, calls `/status`, and rebuilds the stage from `state` +
  `mailboxLinkExpiresAt`/`codeExpiresAt`/`windowEndsAt`: `requested` → mailbox, `mailbox_confirmed` →
  witness, `witness_passed` → the 72-hour window. The request id and address are kept in
  `flutter_secure_storage` (`mfa_reset_request_id`, `mfa_reset_email`); **the password is never
  written**, and the resume field is cleared as soon as the one call returns.
  `401 invalid_credentials` keeps the single `/login` refusal. `404 request_not_found` clears the saved
  id and says the request is gone, with "Start a new request". `cancelled_by_signin`,
  `cancelled_by_link`/`cancelled_by_parent`, `expired`, `too_many_attempts` and `completed` each get a
  sentence that says what happened and what to do next; `completed` is the one with no start-again
  action.
- **A co-parent's approval prompt has a name and a way in.** The dashboard and Settings › Two-step
  verification watch `mfaResetPendingProvider` (`GET /mfa/reset/pending`). A request renders the
  requester's `displayName` and role in the copy, and its id — not a deep link — opens
  `MfaResetApprovalScreen`. A `witness_passed` entry shows the running window and offers only decline,
  because `/approve` would answer `409 request_not_open`. A guardian's `403 role_not_allowed` becomes
  an empty list: no banner, no error page. The deep link still works and now accepts the same fields.
- **Token refresh narrowed to the routes that need it.** `ApiClient` no longer exempts every
  `/v1/auth/*` path from refresh. Credential-only routes (`login`, `register`, `logout`,
  `token/refresh`, `reset/request`, `reset/confirm`, `mfa/recover`, `mfa/reset/{request,confirm,witness,status,complete}`,
  and the emailed-link form of `mfa/reset/cancel`) still answer their own 401. `mfa/reset/pending`,
  `mfa/reset/approve`, the `requestId` form of `mfa/reset/cancel`, `mfa/recovery-codes`, `logout-all`,
  and `mfa/enroll`/`mfa/verify` when they carry the parent session now refresh like any signed-in
  call; a purpose-scoped `mfa_recovery` token in `extra['authToken']` is never swapped for the stored
  session.
- **Copy:** 27 new `mfaReset*` keys in `app_en.arb` and `app_ar.arb`, same keys and placeholders,
  Arabic written as Arabic. The intermediate witness stage after a resume keeps both possibilities in
  its wording because `/status` does not return `witnessKind` until the witness passes.
- **Tests:** `test/mfa_reset_screens_test.dart` gains the restart path (stored id → password → stage,
  401, 404, all five terminal outcomes), the pending list (owner sees, guardian does not, empty list,
  settings, already-approved), named approval, and four Arabic + RTL runs at 320×568.
  `test/api_client_refresh_test.dart` pins the per-route refresh classification and exercises the
  interceptor (pending refreshes and retries; link-form cancel and `/status` do not).

Not verified: no live API was used; the routes were exercised through the app's fake transport against
the contract in `services/api/src/routes/auth.ts`. The co-parent prompt is a banner and a settings
entry, not a push notification — ADR-0031 decision 4's templates are still unbuilt.
