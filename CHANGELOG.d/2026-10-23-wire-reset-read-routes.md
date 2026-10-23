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
  an empty list: no banner, no error page. The deep link still works but carries only `requestId`: the
  name, role and state come from `/pending`, matched by id (review of #314).
- **Token refresh narrowed to the routes that need it.** `ApiClient` no longer exempts every
  `/v1/auth/*` path from refresh. Credential-only routes (`login`, `register`, `logout`,
  `token/refresh`, `reset/request`, `reset/confirm`, `mfa/recover`, `mfa/reset/{request,confirm,witness,status,complete}`,
  and the emailed-link form of `mfa/reset/cancel`) still answer their own 401. `mfa/reset/pending`,
  `mfa/reset/approve`, the `requestId` form of `mfa/reset/cancel`, `mfa/recovery-codes`, `logout-all`,
  and `mfa/enroll`/`mfa/verify` when they carry the parent session now refresh like any signed-in
  call — but only on the session's own 401 (`unauthorized` / `session_revoked`): a mistyped code
  (`invalid_code`) or password (`reauth_required`) is the answer, and refreshing it would replay the
  same wrong secret and, if the refresh failed, delete both tokens. A purpose-scoped `mfa_recovery`
  token in `extra['authToken']` is never swapped for the stored session.
- **Copy:** 27 new `mfaReset*` keys in `app_en.arb` and `app_ar.arb`, same keys and placeholders,
  Arabic written as Arabic. `/status` does not return `witnessKind` until the witness passes, but a
  null `codeExpiresAt` in `mailbox_confirmed` means the family had no paired device: the resume then
  says a co-parent is the only witness and offers no code entry (review of #314).
- **Tests:** `test/mfa_reset_screens_test.dart` gains the restart path (stored id → password → stage,
  401, 404, all five terminal outcomes), the pending list (owner sees, guardian does not, empty list,
  settings, already-approved), named approval, and four Arabic + RTL runs at 320×568.
  `test/api_client_refresh_test.dart` pins the per-route refresh classification and exercises the
  interceptor (pending refreshes and retries; link-form cancel and `/status` do not).

**Review of #314 (2026-10-23) — the must-fix, the three shoulds and the Arabic copy, all applied.**

- **A deadline that ran out is no longer a dead end (must).** `MfaResetWaitingScreen` computes
  `deadlinePassed` from the same `_now` as the window check (`mailboxExpiresAt` while `requested`,
  `codeExpiresAt` while `mailbox_confirmed`); when it is true the code entry is gone, a new
  `mfaResetDeadlinePassed` line is shown, and the existing "Start a new request" button is offered.
  Without it the parent looped between the waiting screen and the request screen until the 24-hour
  sweep, because `/request` redirects straight back while an id is stored. The 72-hour window never
  offers it: `/request` answers `409 reset_already_pending` there.
- **Refresh only the session's own 401 on `/v1/auth/*` (should).** `shouldRefreshOn401` now takes the
  response; `invalid_code` on `/mfa/verify` and `reauth_required` on `/mfa/enroll` /
  `/mfa/recovery-codes` no longer refresh and replay, so a typo cannot spend a second rate-limit slot,
  trigger a second password check, or sign the parent out by failing a refresh.
- **No device code, no "Enter code" (should).** `MfaResetProgress` carries `deviceCode` and
  `witnessDeadline` from `/status`; a `mailbox_confirmed` with a null `codeExpiresAt` hides the code
  entry and shows "Waiting for your co-parent to approve, by …".
- **The approval deep link trusts only the id (should, latent).** `/mfa/reset/approve?requestId=`
  builds `MfaResetApprovalLink`, which watches `mfaResetPendingProvider` and matches by id. `name`,
  `role`, `state` and `windowEndsAt` in the URL are ignored; an id that is not in the list falls back
  to the generic copy.
- **Arabic.** «تجاوز خطوة الشاهد» → «اجتاز خطوة الشاهد» in `mfaResetApproveAlready` and
  `mfaResetPendingAlreadyWaiting`; `mfaResetPendingMore` is an ICU plural (`وطلب آخر` / `وطلبان آخران` /
  `و… طلبات أخرى` / `و… طلبًا آخر`), where the old string was wrong for 1, 2 and 11+; the banner and the
  named intro read «وصل طلب من {name} ({role}) … بعد فقدان …»; `mfaResetTerminalTooManyAttempts` is
  ungarbled. The review's two nits are taken with them («على هذا الهاتف», «مالك»).
- **The resume password is cleared on the failing path too.** `if (mounted) _resumePassword.clear()`
  in `finally`, and the saved id is forgotten before the `mounted` check, so a 404 or terminal answer
  that lands after the screen closed still clears it. The password is still never written anywhere.
- **Tests.** `mfa_reset_screens_test.dart` gains the two ran-out stages, the no-code stage, the
  thrown-`/status` password clear (and the empty field after a 401), the deep link (by widget and
  through the real router with a crafted URL), two Arabic + RTL renders at 320×568 and two Arabic copy
  tests. `api_client_refresh_test.dart` keeps its 9 cases and adds two interceptor cases proving
  `/mfa/verify` and `/mfa/enroll` are neither refreshed nor replayed. Mutation-checked, each failing
  the named test: `_deadlinePassed` → `false` (both ran-out tests), removing the password clear (the
  throw test sees `good-password` still in the field), dropping the `/v1/auth/` error gate (four
  refresh tests), not passing the response (the two live-session refreshes), `deviceCode: true` (the
  no-code test), and the old Arabic plural (renders «و1 طلبات أخرى»).
- **Deliberately not tested:** removing `mfaResetPendingProvider`'s `try/catch` pins nothing — both
  readers use `.valueOrNull ?? []`, so an escaped error and a caught one render the same, and the
  provider is documented as never throwing. The review's remaining nits (`mfaResetTerminalCompleted`
  offering start-again; the `mfa_reset_store.dart` comment calling `requestId`+code "not a credential")
  are left for the next pass, as the review allows.

Not verified: no live API was used; the routes were exercised through the app's fake transport against
the contract in `services/api/src/routes/auth.ts`. The co-parent prompt is a banner and a settings
entry, not a push notification — ADR-0031 decision 4's templates are still unbuilt.
