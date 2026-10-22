### API — MFA reset follow-ups: the three gaps from the #305 review (ADR-0031 amendment, #305)

Records the three decisions from Claude's review of #305 in ADR-0031 as a dated amendment, and builds
the two that change behaviour. The third (`witnessRef` stays `null` for a device witness) is a record
of what the code already does; no code changed for it.

- **A `witness_passed` request that is never completed now expires seven days after `windowEndsAt`.**
  Fourth sweep in `services/api/src/jobs/mfaResetExpiry.ts:63` —
  `state = 'witness_passed' AND windowEndsAt <= now - 7 days` → `expired`, `outcomeAt = now`, counted
  in the run as `witnessPassedExpired` and logged with the other counts. Without it, a parent who
  passed the witness and did not come back was locked out of asking again for ever: decision 7 allows
  one open request per parent, and `request` may not replace a `witness_passed` row. `complete` on the
  expired row answers `409 request_expired`. Seven days covers a week away after the window; the
  parent then starts again with a fresh witness. The constant is
  `MFA_RESET_WINDOW_GRACE_MS` (`services/api/src/lib/mfaReset.ts:62`).
- **`POST /v1/auth/mfa/reset/request` supersedes the parent's own open request when it is `requested`
  or `mailbox_confirmed`** (`services/api/src/routes/auth.ts:708`). The old row becomes `expired` with
  `outcomeAt = now`, its `show_reset_code` payloads are cleared through `clearResetCodePayloads`, and
  the new request is created as before (`200`). A `witness_passed` request still answers
  `409 reset_already_pending`; its window is not restartable. The three-requests-per-30-days count is
  unchanged and counts superseded rows, so this grants no extra attempts; the count is now evaluated
  before the supersede, so a request that will be refused as the fourth does not expire the open one it
  cannot replace (`429 reset_limit_reached`). Before this, a parent who could not reach the child's
  phone inside the code's ten minutes sat in `mailbox_confirmed` — or in `requested` — answering
  `reset_already_pending` until the 24-hour sweep, having already spent one of the three attempts.
- **`witnessRef` stays `null` for a device witness** (ADR-0031 decision 8 as amended): one code goes to
  every paired device, so no single device can be named. `witnessKind` discriminates the two
  witnesses. Pinned by an existing test, not a new behaviour.
- **Recorded, not built here:** the `/login` cancel path clears the cancelled request's
  `show_reset_code` payloads — merged in #305 at `384a188`
  (`services/api/src/routes/auth.ts:275`). The ADR amendment says so, so the record matches the code.
- **Tests:** `services/api/test/mfa-reset-expiry.test.ts` (+1: 8 days vs 6 days after the window) and
  `services/api/test/mfa-reset.test.ts` (+3: supersede of a `mailbox_confirmed` request, supersede of a
  `requested` one, `witness_passed` still `409`; the one-open-request/three-per-30-days test now covers
  the supersede and that a refused fourth request supersedes nothing). All four fail with the two
  source changes stashed — `expected undefined to be 1`, `expected 409 to be 200` ×3 — and pass after.
  `pnpm --filter @familyshield/api test`: **501 passed**, up from the 497 on this branch.
- **Docs in the same change:** `docs/adr/0031-mfa-reset-family-witness.md` gains
  `## Amendment 2026-10-22 — Claude, on #305 review: the three gaps` (context → decision → why →
  falsifiable claims; the accepted decision text is untouched); `docs/SPEC.md`'s "MFA reset with a
  family witness" state table, `request` row and known gaps are updated; `docs/ROADMAP.md` row 3.3
  records this stacked PR next to the #305 entry.
- **Not built, unchanged from #305:** the email and push templates, the 24-hour reminder, the parent-app
  screens, the Android `show_reset_code` screen and the read-only audit route. Nothing in the client
  apps reads the seven-day expiry yet, because nothing in them drives the reset flow at all.
- **Not verified here:** `qa-probe` and `e2e` were not run — no live stack in this environment, the same
  disclosure as #305's fragment. The suite, `tsc`, the changelog-fragment check and the docs-link check
  were run; their output is in the PR.
