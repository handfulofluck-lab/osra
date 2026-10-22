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
- **`O23`** a family with no paired device and no other `owner`/`co-parent` answers `409 no_witness` three
  times; after a device is paired, the next request is an ordinary `200`. A stored row per refusal would
  have hit decision 7's limit (`429 reset_limit_reached`) instead. (`no_witness` is answered before any row
  is read, so a second refusal alone would prove nothing — Claude's review found exactly that: a mutant
  that stored a row per refusal still passed the earlier version of this check.)

**A Windows-only crash on the early-exit path, found by running the stub test here.** With the `call()`
change, a failing `setup:` check reaches `process.exit(1)` while a `fetch` keep-alive socket is closing, and
on Node 24/Windows the process dies with `0xC0000409` (libuv: `Assertion failed: !(handle->flags &
UV_HANDLE_CLOSING)`) instead of exiting `1` — so the stub test read a crash rather than a FAIL. The early
exit now sets `process.exitCode` through a `StopRun` sentinel and lets the loop drain, which is what the
rate-limit aborts already did for the same reason (`scripts/qa-probe.mjs:103`). Measured: manual stub run
`exit=1` with the FAIL printed, and `test/qa-probe-rate-limit.test.ts` 4/4.

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

**Measured live (Claude, 2026-10-22 22:30Z):** `162 passed, 0 failed` against a real API, with **20**
`/login` calls per run against the route's `max: 20` and **0 × 429** in every run. `O18` was confirmed to
catch the history leak: with the payload un-redacted the check fails, and it is the only thing that would.

**One fix the live run forced.** `call()` treated *every* `429` as `@fastify/rate-limit` throttling —
retried, then aborted with `ABORT: rate limited by the API … wait 60 s and re-run`, exit `2`. But decision
7's limit refusal is also a `429` (`{"error":"reset_limit_reached"}`), so a genuine regression there would
have read as "slow down and try again" and a verifier would have re-run instead of filing a bug. `call()`
now inspects the body: a `429` whose `error` is one the API answers itself (`APP_429_ERRORS`, today only
`reset_limit_reached`) is handed back to the check that asked for it; every other `429` (the limiter's
`Too Many Requests`, a proxy's, the `rate_limited` stub in `test/qa-probe-rate-limit.test.ts`) is
throttling, as #112 requires. The first version of this change turned it round (anything but `Too Many
Requests` was an answer) and broke #112's two stub tests in CI; `qa-probe-rate-limit.test.ts` now also
pins the limiter's real body as throttling and `reset_limit_reached` as an answer (exit `1` with a `FAIL`,
no `ABORT`). With that change, a mutant that stores a row per refusal produces a clean `FAIL O23` instead
of an abort.
