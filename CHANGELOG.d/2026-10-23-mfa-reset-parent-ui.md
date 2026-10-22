### Parent app — the MFA reset screens: request, wait, witness, co-parent approval (ADR-0031, #297)

The parent-app half of ADR-0031, on top of the six `/v1/auth/mfa/reset/*` routes already on `main`.
A parent who has lost the authenticator **and** every recovery code can now ask for a reset from the
app, wait out the 72-hour window, and finish into ADR-0023's re-enrolment.

- **Client** (`apps/parent-app/lib/api/mfa_reset_api.dart`): `request`, `confirm`, `submitWitness`,
  `approve`, `cancel`, `complete`, with a typed `MfaResetFailure` that keeps only the distinctions the
  API makes — `401 invalid_credentials` is one answer for an unknown address and a wrong password,
  `401 invalid_witness` is one answer for an unknown request, an expired code and a wrong code, and
  `404 request_not_found` is one answer for "no such request" and "another parent's request". Models
  are in `lib/api/models.dart`.
- **Request screen** (`mfa_reset_request_screen.dart`): email + password and the full sequence in
  words (mailbox link → 8-digit code from the child's phone or another parent's approval → 72-hour
  wait). Refusals map to their own copy: `mfa_not_enabled`, `no_witness` (ADR-0031 decision 6),
  `reset_already_pending` and `reset_limit_reached`; generic 429/400/network stay generic.
- **Waiting state** (`mfa_reset_waiting_screen.dart`): the stage (mailbox / witness / window), the
  deadline the server returned, the next action, the cancel path, and — once `windowEndsAt` has passed
  — the `complete` step, which hands the 15-minute `mfa_recovery` token to the existing enrolment
  screen and never writes it to the session slot.
- **Witness entry** (`mfa_reset_witness_screen.dart`): numeric keyboard, digits-only, eight digits.
  `attemptsRemaining` is shown only when the server sends it (a wrong code); every other
  `invalid_witness` gets the single "not accepted or expired" message. Five wrong codes disable the
  button, matching `too_many_attempts`.
- **Co-parent approval** (`mfa_reset_approval_screen.dart`, route `/mfa/reset/approve?requestId=`):
  Approve (`/approve`) and Decline (`/cancel`, `cancelled_by_parent`), with `role_not_allowed` and
  `forbidden` said in words.
- **Entries:** the login screen's lost-authenticator recovery screen gains "No recovery code left?
  Request a reset", and Settings › Two-step verification gains the reset route plus a note beside the
  codes stating that a family witness is the only way back once both are gone (ADR-0031 decision 6).
- **Copy:** 65 `mfaReset*` keys in `app_en.arb` and `app_ar.arb`, same keys and placeholders; the
  Arabic is written as Arabic (`إعادة تعيين التحقق بخطوتين`, `شاهد من العائلة`, `فترة الانتظار`), not
  a literal gloss.
- **Tests:** `apps/parent-app/test/mfa_reset_screens_test.dart` (32 tests) — every surface, every
  failure copy, the cancel path, the `window_open` refusal, and five Arabic + RTL runs at 320×568
  asserting no layout exception. `flutter analyze` clean; `flutter test` 292 passed (32 of them new —
  main had 260).

**API gaps this half does not close** (reported, not invented):

- **No read route.** Nothing lets the app ask for a request's current state, and ADR-0031 decision 8's
  read-only audit route is unbuilt. The waiting screen therefore cannot be rebuilt after an app
  restart; it shows only what `request`/`witness`/`approve` returned in the same session, and nothing
  is persisted. That part of the waiting-state requirement is not met until the API exposes a read.
- **`/approve` takes only `{requestId}`.** It returns no requester identity, so the approval prompt
  cannot say who is asking; and decision 4's email/push templates are unbuilt, so no notification
  delivers the request id to a co-parent's app. The route exists for the future deep link.
- **The subject cannot cancel from the app.** `/cancel` with a session refuses the request's own
  parent (`403 forbidden`); cancellation for them is the emailed link or a successful sign-in. The
  waiting screen surfaces that refusal with the link as the way out.

Not verified: no live API was used — the routes were exercised through the app's fake transport, from
the contract in `services/api/src/routes/auth.ts`. The Android `show_reset_code` screen (which draws
the code) is still unbuilt, so the device-code witness cannot be walked end-to-end on a handset.
