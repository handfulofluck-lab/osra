### API — the probe gates ADR-0031's MFA reset, including the witness-code leak in the command history (#297)

`services/api/scripts/qa-probe.mjs` gains `O14`–`O23` — ten checks, plus a `setup:` check that builds the
family they need — every one gating. Nothing is mocked; the flow is walked against the live API.

- **`O14`** `/v1/auth/mfa/reset/request` answers a wrong password and an unknown address with exactly
  `/login`'s status and body. Both sides are compared, so a shared wrong answer fails too.
- **`O15`** `POST /v1/devices/:id/command {command:"show_reset_code"}` is refused `400` and nothing is
  queued: the mailbox confirmation is the command's only producer.
- **`O16`** no `show_reset_code` row exists before the mailbox link is clicked, and exactly one exists
  after it.
- **`O17`** the 8-digit code is readable from the child's own device queue, bound to the request id, and
  from nowhere else.
- **`O18`** the parent-facing `GET /v1/devices/:id/commands/history` lists that row with its status and
  `expiresAt` but carries no `code` — and the plaintext code does not appear anywhere in the response
  body. This is the #305 review finding; the check fails if it regresses.
- **`O19`** a `guardian` of the family (`403 role_not_allowed`) and the owner of another family
  (`403 forbidden`) cannot approve the reset.
- **`O20`** `POST /v1/auth/mfa/reset/complete` before `windowEndsAt` answers `409 window_open`, and the
  factor is still bound: a password-only `/login` is `401 mfa_required`, not `mfa_reenroll_required`.
- **`O21`** a second `request` while the first is `witness_passed` answers `409 reset_already_pending`;
  the window is not restartable.
- **`O22`** a successful `/login` by the parent during the window cancels the request, and `complete`
  then answers `409 request_cancelled`.
- **`O23`** a family with no paired device and no other `owner`/`co-parent` answers `409 no_witness`, and
  a second request is refused the same way — a stored `requested` row would have been superseded and
  answered `200`, so the second refusal is the proof that nothing was stored.

**Obtaining the mailbox link:** `O16`–`O22` need the `confirm` token. The probe has no inbox, so it uses
the `confirmToken` that `/mfa/reset/request` echoes while no email provider is configured and `NODE_ENV`
is not production (`echoResetTokens`, `services/api/src/routes/auth.ts`). On a stack with
`RESEND_API_KEY`/`EMAIL_FROM` set the echo is gone; the run then prints one `target` naming the checks it
could not walk instead of passing them silently.

**Not asserted here:** the seven-day post-window expiry (ADR-0031 amendment 2026-10-22, gap 1) is a
database clock the probe cannot wait for. It stays covered by `services/api/test/mfa-reset-expiry.test.ts`
and the job in `services/api/src/jobs/mfaResetExpiry.ts`.

**Cleanup:** the accounts are `qa-mfa-*@example.com`, so `services/api/scripts/cleanup-test-data.sql`
removes their families, and `MfaResetRequest.parentId` cascades from `Parent`; the guardian's original
family ends up empty and the script's orphan rule removes it. The probe has no database connection, so it
cannot delete rows itself.

**Not verified here:** the probe was not run — no live stack in this environment. `node --check` is clean
and `scripts/check-probe-integrity.mjs` reports 11 added, 0 removed or demoted, but the checks themselves
are unexercised until a verifier runs `node scripts/qa-probe.mjs`. One thing that live run should check
first: `/login` now takes **19** calls per run (14 before) against a `max: 20` per-minute route limit. They
are spread over the run — two 30-second TOTP waits separate the MFA sections, and roughly six fall in the
tightest minute — so the budget should hold, but nothing in this change measured it, and a `429` burst
aborts the run with exit `2` rather than recording a false failure (issue #112).
