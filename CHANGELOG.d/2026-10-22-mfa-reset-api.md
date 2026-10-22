### API — MFA reset with a family witness and a 72-hour window (ADR-0031, #297)

The API half of ADR-0031: a parent who has lost the authenticator **and** every recovery code can get
back in without an operator. Four factors in order — password, mailbox, a family witness, then a 72-hour
window — and the route ends in ADR-0023's existing recovery token, so there is still exactly one path to
"MFA cleared".

- **`MfaResetRequest`** (`services/api/prisma/schema.prisma:90`, migration `0023_mfa_reset_request`).
  State, `windowEndsAt`, `codeHash` (SHA-256 only), `failedCodeAttempts`, `emailConfirmedAt`,
  `witnessKind`/`witnessRef`/`witnessAt`, `completedAt`, `cancelledReason`, `outcomeAt`. No IP address,
  user agent or free text; additive, so a pre-0031 API binary ignores the table.
- **Routes** in `services/api/src/routes/auth.ts`: `request` (`:649`), `confirm` (`:722`), `witness`
  (`:807`), `approve` (`:851`), `cancel` (`:877`), `complete` (`:949`). `request` has `/login`'s refusal
  (`401 invalid_credentials`, checked against a dummy hash for an unknown address) and `/login`'s 20/min
  bucket; `confirm` consumes a single-use 30-minute link and only then sends `show_reset_code` to every
  paired device of the family; `witness` takes the 8-digit code and five wrong ones end the request;
  `approve` accepts another `owner`/`co-parent` of the same family and refuses a `guardian` and another
  family; `cancel` serves the one-click link and a signed-in other parent; `complete` is refused before
  `windowEndsAt` and runs ADR-0023's sequence verbatim (`mfaEnabled` true, `mfaSecret` null, codes
  deleted, every session revoked, 15-minute `purpose:"mfa_recovery"` token).
- **Sign-in cancels a pending reset**: `POST /v1/auth/login` writes `cancelled_by_signin` for an open
  request of that parent before minting a session (`services/api/src/routes/auth.ts:265`), so however a
  request got that far, a parent who can sign in closes it.
- **`show_reset_code`** is produced only by `POST /v1/auth/mfa/reset/confirm` through
  `enqueueDeviceCommand`; it is **not** in the parent command allow-list and **not** in
  `SAFE_DIRECTION_COMMANDS` (#305 review — see the fixes below). It restricts nothing, which is
  ADR-0031 decision 2.3's own classification under ADR-0019, and that classification now belongs to
  the internal producer. Its row lives 10 minutes (`services/api/src/lib/deviceCommands.ts:42`)
  and its plaintext payload is cleared on ack (`:207`), on expiry and on a passed/cancelled witness.
- **Expiry job** (`services/api/src/jobs/mfaResetExpiry.ts:42`, started in `src/server.ts:127`): 24 hours
  from the mailbox confirmation without a witness → `expired`; 24 hours from creation without the mailbox
  click → `expired`; `outcomeAt` older than 12 months → deleted; expired `show_reset_code` payloads
  cleared.
- **Tests:** `services/api/test/mfa-reset.test.ts` (29), `test/mfa-reset-expiry.test.ts` (7),
  `test/mfa-reset-rate-limit.test.ts` (1), plus one safe-direction assertion in `test/consent.test.ts`.
  Each ADR-0031 falsifiable claim 1a–7 is named in a test title where a test covers it.
  `pnpm --filter @familyshield/api test`: **494 passed**, up from the 457 on `main`; `npx tsc --noEmit -p
  services/api` clean after `prisma generate`.
- **Not built in this change** — deliberately, and stated here rather than discovered later:
  - the **parent-app screens** (request, waiting state, the co-parent's approval prompt, cancel);
  - the **Android child screen** for `show_reset_code` — the command exists and is dispatchable, nothing
    on the phone renders it yet;
  - the **email and push templates** (ADR-0031 decision 4): the send points are `[mfa-reset] ... hook`
    log lines, so in production the confirm/cancel link is not delivered anywhere;
  - the **24-hour reminder** before the window ends — the expiry job says so and sends nothing;
  - the **read-only audit route** (ADR-0031 decision 8, "who reads it");
  - the **probe checks** the ADR lists as part of the API work: `qa-probe`/`e2e` were not run here
    because there is no live stack in this change's environment.
- **Two ADR gaps observed while building, not decided here:** a `witness_passed` request that is never
  completed has no expiry in ADR-0031 (only the witness step has a deadline), so it stays open and keeps
  blocking the parent's next request; and `witnessRef` cannot name a single device for a device witness,
  because one code is shown on every paired device (stored `null`). Response codes the ADR does not name
  (`mfa_not_enabled`, `reset_already_pending`, `reset_limit_reached`, `request_not_open`,
  `invalid_witness`, `too_many_attempts`, `window_open`, `request_cancelled`, `request_expired`,
  `witness_required`, `request_completed`) were chosen to match the existing vocabulary in this file.
- **Review fixes (#305, Claude, live):** two ways to defeat the witness, both closed.
  - `GET /v1/devices/:id/commands/history` returned the plaintext 8-digit `show_reset_code` to any family
    parent — the guardian, or the parent being reset — so the code could simply be read out of the parent app.
    He demonstrated it by passing the witness live with a code a guardian had read. The history now blanks the
    payload of device-only types (`DEVICE_ONLY_PAYLOAD_TYPES` in `services/api/src/lib/deviceCommands.ts`) and
    keeps the row, the status and the timestamps; a test asserts the body contains no code and that other
    commands are untouched.
  - `show_reset_code` was in the **parent** `CommandSchema` and in `SAFE_DIRECTION_COMMANDS`, so any family
    parent could put a reset notice with a code of their choosing on the child's phone. It is now produced only
    by `POST /v1/auth/mfa/reset/confirm` through `enqueueDeviceCommand`, and a parent POST is a `400`; both are
    pinned by tests. It stays safe-direction by ADR-0031 decision 2.3 — that classification belongs to the
    internal producer, not to the set that answers "may this parent send it".
  - `/login` also clears the cancelled request's `show_reset_code` payloads, so a code for a dead request cannot
    keep showing on the child's phone for its remaining ten minutes (Claude's item 4).
  - Verified by mutation: with the two source changes stashed the new tests fail exactly as expected
    (`expected { requestId: 'req-1', … } to deeply equal {}` and `expected 200 to be 400`).
