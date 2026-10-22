# ADR-0031 — MFA reset when every recovery code is gone: a family witness and a 72-hour window, no support operator

**Status:** accepted (2026-10-22)
**Date:** 2026-10-22
**Deciders:** Claude (architecture). Karim delegated the decision on #297, quoted there by Kimi Code at
18:03Z: *"Im not clear whats being asked from me in 297 but seems like an architecture decision let
claude decide on that please."* Filed by Kimi Code (development lead) as #297.
**Supersedes:** ADR-0023 decision 6 ("the existing locked-out cohort needs Option B, and that is the
maintainer's call") and ADR-0023's Option B verdict ("deferred to the maintainer"). Everything else in
ADR-0023 stands, including recovery codes as the primary path and the rejection of Option C.
**Related:** ADR-0004 (optional MFA), ADR-0013 (retention and erasure), ADR-0019 (safe-direction
commands), ADR-0023 (MFA recovery), ADR-0025 (session revocation counter); issues #136, #183, #199, #297.

## Context

- **Who this is for.** A parent with MFA on who has lost the authenticator **and** has no unused
  recovery code. That covers four cases:
  - the parent enrolled before codes shipped and never regenerated them;
  - the code sheet was lost with the phone;
  - the last code is spent;
  - the 15-minute recovery token was lost before `/mfa/verify` (#199 item 2).

  Today this parent has no route back. `/login` needs a TOTP, `/mfa/recover` needs a code, and there is
  no support role, admin route or operator (ADR-0023, "What a parent does today").
- **What is at stake in both directions.**
  - **Too weak.** This account controls a child's phone and reads the child's location and alerts, so
    a route that is too weak hands that to whoever can fool it. For a family product the realistic
    attacker is not a stranger. It is someone who knows the family: a former partner, or a relative
    with access to the child's phone on some days. That person is also the one best placed to pass a
    human identity check.
  - **No route at all.** The parent is stranded. The child's phone keeps enforcing rules nobody can
    change, and the only way out is removing the app from the child's phone (a factory reset at worst,
    since the app is deliberately not device owner).
- **What already exists and can carry this.**
  - The account's mailbox, already proven by the password-reset link.
  - Each parent's push tokens (`ParentPushToken`).
  - An authenticated command channel to every paired child device (`services/api/src/routes/devices.ts`,
    `CommandSchema`).
  - The session revocation counter (ADR-0025).
  - ADR-0023's purpose-scoped recovery token, which ends in forced re-enrolment and a fresh batch of
    codes.
- **What does not exist, and should not be created for this.**
  - A support desk, an admin surface or an operator role.
  - Storage of identity documents. Families are in several jurisdictions, and their data is held in
    Frankfurt (ADR-0030).

## Decision

1. **The route exists, it is automated, and there is no operator.** Nobody at OSRA can clear a parent's
   second factor by hand, so nobody can be talked into doing it.
2. **Four things are required, in this order.**
   1. **The account password.** `POST /v1/auth/mfa/reset/request` takes `{email, password}`, with the
      same rate limit and the same refusal as `/login`.
   2. **The account's mailbox.** A single-use confirmation link, valid 30 minutes. Nothing is sent to a
      child device before it is clicked.
   3. **A family witness**, either of these:
      - **A paired child device.** The API sends a new command, `show_reset_code`, to every paired device
        of the family. It restricts nothing, so it is safe-direction under ADR-0019 and needs no active
        consent. The child app shows a full-screen notice naming the parent, an 8-digit code valid
        10 minutes, and the line "Show this only to your parent, in person. OSRA will never ask you for
        it." The parent types the code into the parent app. Five wrong codes end the request.
      - **Another parent's approval.** A second parent of the same family with role `owner` or
        `co-parent` approves from their own signed-in app. A `guardian` cannot approve: guardian access
        is deliberately partial.
   4. **A 72-hour window.** It starts when the witness step passes. At that moment every session of the
      parent being reset is revoked (ADR-0025), so a lost or stolen phone that is still signed in is cut
      off.
3. **What cancels the request.**
   - **Any successful sign-in by that parent during the window.** After step 4's revocation, a sign-in
     needs the authenticator. A parent who can sign in is not locked out, so the request was not theirs.
     This is the main defence, and it needs nobody to read anything.
   - **The cancel link** in any email about the request. It is one click with no sign-in, because
     cancelling can only keep things as they are.
   - **Any other `owner` or `co-parent`** of the family, from their app.
   - **Expiry.** The request ends if the witness step is not done within 24 hours of the mailbox
     confirmation.
4. **Who is told, and when.**
   - **Who:** the account's email address; every push token registered to that parent; and, by email and
     push, every other `owner` and `co-parent` of the family.
   - **When:** when the window starts, 24 hours before it ends, and when it completes.
   - **What each message says:** when the reset will happen, with the cancel link.
5. **How it ends.** After the window, `POST /v1/auth/mfa/reset/complete` takes
   `{email, password, requestId}` and runs ADR-0023's recovery sequence exactly as amended on 2026-10-22:
   1. register the recovery token's record;
   2. revoke all sessions;
   3. one transaction that clears `mfaSecret`, deletes any remaining codes and records the outcome;
   4. sign the 15-minute `purpose: "mfa_recovery"` token.

   From there it is the existing forced re-enrolment, which issues a new batch of codes. This adds no new
   token type and no new kind of session.
6. **No witness, no reset.** This applies to a family with no paired child device and no other `owner`
   or `co-parent`, and to one whose only devices are lost with the parent's phone.
   - The parent app says so plainly when the request is made, and in the MFA setup copy beside the codes.
   - With no paired device, nothing on a child's phone is stranded. The parent can sign up again with
     another address.
   - Freeing the old address needs parent-account erasure. That does not exist yet (ADR-0013 covers
     children only); it is named here as a gap, not designed.
7. **Limits.**
   - One open request per parent, and at most three requests per parent in any 30 days.
   - The request stores only the SHA-256 of the device code. The plaintext exists only in the
     `show_reset_code` payload, which is cleared from the command row when the device acknowledges it or
     the code expires.
8. **Audit record.** A new table, `MfaResetRequest`, holds one row per request with these fields:
   - `parentId`, `familyId`;
   - `createdAt`, `emailConfirmedAt`;
   - `witnessKind` (`device` or `parent`), `witnessRef` (the device id or the approving parent's id),
     `witnessAt`;
   - `windowEndsAt`;
   - `failedCodeAttempts`;
   - `outcome` (`completed`, `cancelled_by_signin`, `cancelled_by_link`, `cancelled_by_parent`, `expired`
     or `too_many_attempts`) and `outcomeAt`.

   There are no IP addresses, user agents or free text. Timestamps are filled in once each, and the
   outcome is written once.

   **Who reads it:** the parent it is about and the family's `owner`, through a read-only API route. No
   application role reads it for anyone else, because there is no operator. Whoever operates the
   production database can see it, as with every table.

   **Retention:** 12 months after `outcomeAt`, then deleted by the retention job.

## Reasoning

- **Why a family witness.** It is the one thing a genuine parent almost always has: their child's phone,
  usually in the same home, or a second parent. A remote attacker with a leaked password and a
  compromised mailbox does not have it.
- **The witness alone is not enough; the window and the sign-in cancel cover that.** The realistic
  attacker may reach the child's phone on some days, or talk a child into reading a code out. In that
  scenario the real parent is not locked out: they still have the authenticator and use the app. Their
  first sign-in during the window kills the request, and every message in it tells them it happened.
- **Why 72 hours.** ADR-0023 suggested 48–72 hours. Three days covers a weekend away from email. A
  genuinely locked-out parent pays with three days of not changing rules, while the child's phone keeps
  enforcing the existing ones, so the cost of the wait is convenience, not safety.
- **Why no operator.** A human identity check is a judgement call that a convincing impersonator wins,
  and the most convincing impersonator of a parent is someone close to the family. An operator also
  needs:
  - staffing;
  - an admin surface that is itself a target;
  - a store of passports or ID cards.

  The automated route asks only for things that cannot be talked into existence.
- **Why it ends in ADR-0023's token.** The enforcement point already exists, is tested (19 cases in
  `services/api/test/mfa-recovery.test.ts`) and is probe-gated. A second path to "MFA cleared" would be a
  second thing to get right.

## Alternatives considered

- **ID document or video check by a support operator** (ADR-0023's Option B as written). Rejected for the
  reasons above: judgement, staffing, an admin surface and document storage. The attacker most likely to
  pass it is the one this product most needs to stop.
- **A call or SMS to a phone number on file.** Rejected. OSRA holds no verified numbers, SIM swap defeats
  it, and the lost phone is usually the number on file.
- **No route** (ADR-0023's Option D). Rejected again as the general answer, because it strands the parent
  with a child's phone nobody can manage. It remains the answer when no witness exists (decision 6).
- **Mailbox and delay only** (ADR-0023's Option C with its safeguards). Rejected. The witness is exactly
  what separates this decision from C.
- **Second-parent approval as the only witness.** Rejected, because it leaves out single-parent families.
  It stays as one of the two witnesses.
- **The parent types a code into the child's phone, instead of reading one from it.** The strength is the
  same, but it needs text input on every agent's block screen. Showing a code is simpler and works on
  every agent that can draw a screen.

## Consequences

**Good**

- Any parent with a paired child device or a second parent can get back in without an operator and
  without sending anyone a document.
- No new credential authority: the route ends in the recovery token and re-enrolment that already exist.
- Attempts are loud. The child's phone, every other parent, and the parent's own phones and mailbox all
  hear about one.

**Bad / costs**

- **Build:**
  - one migration (`MfaResetRequest`);
  - routes to request, confirm the email, submit the code, approve, cancel and complete;
  - the `show_reset_code` command and its screen in the Android child app, and in every later agent
    (iOS included);
  - four email templates and the matching push messages;
  - a job for expiry and the 24-hour reminder;
  - parent-app screens: the request, the waiting state, the co-parent's approval prompt and cancel;
  - new probe checks.
- **The child sees that a parent asked for a reset.** The copy must be calm and age-appropriate, in
  English and Arabic.
- **A genuinely locked-out parent waits 72 hours.**
- **A child can be talked into reading the code out.** This is reduced by the copy, the window, the
  sign-in cancel and the messages to every other parent; it is not removed.
- **A family whose devices were lost with the parent's phone, and which has no second parent, has no
  route** (decision 6).
- **Residual risk (named):** an attacker who holds the password, the mailbox and either the child's phone
  or the second parent's help wins against a real parent who neither signs in nor reads email or push for
  72 hours.

## Falsifiable claims (for the implementing PR's verifier)

1. **Each factor is required.**
   - A wrong password gets the same answer as `/login`.
   - Without the mailbox click, no `show_reset_code` command is created.
   - Five wrong codes end the request as `too_many_attempts`.
   - `complete` before `windowEndsAt` changes nothing.
2. **Passing the witness step revokes the parent's sessions:** the parent's session version goes up by
   exactly one.
3. **A successful `/login` by that parent during the window cancels the request:** the outcome is
   `cancelled_by_signin`, and `complete` is refused.
4. **A guardian cannot approve.** An `owner` or `co-parent` of another family cannot either.
5. **`complete` produces exactly ADR-0023's recovered state:**
   - `mfaEnabled` true with `mfaSecret` null;
   - no codes left;
   - every session revoked;
   - a token that only `/mfa/enroll` and `/mfa/verify` accept.
6. **After acknowledgement or expiry, the plaintext code is in no database row.**
7. **A family with no paired device and no other `owner` or `co-parent` is refused at request time with
   `no_witness`.** Nothing is sent and nothing is stored beyond the refusal's rate-limit counter.

## Sequencing

- **This ADR is the decision only; no code changes here.** Kimi Code offered on #297 to build it against
  this ADR, in its own PRs. The natural split is API with probe checks first, then the Android child
  screen, then the parent app.
- **It does not block staging.** It must ship before the public launch.
- **Until it ships,** the parent app's MFA setup must keep saying that the codes are the only way back.
  ADR-0023's rule that the recovery email promises no support channel still holds, because there is
  none.

## Amendment 2026-10-22 — Claude, on #305 review: the three gaps

**Status:** accepted (2026-10-22), in review of PR #305 (`feat/297-mfa-reset-api`, head `384a188`).
**Scope:** amends decisions 7 and 8 and adds one expiry clock. The decision text above is left as it was
accepted; this section is the record of what changed and why (`AGENTS.md` §8: never edit an accepted
decision, supersede it).

### Context

The API half of this ADR was built in #305 and reviewed. Three gaps survived it, all in the seam between
"the parent asked" and "the parent finished or gave up", plus one thing the code already does that the
record did not say:

- **A `witness_passed` request had no end.** Decision 3 sets a deadline for the witness step (24 hours
  after the mailbox confirmation) and decision 2.4 sets the 72-hour window, but nothing closed a request
  whose window had long passed and whose parent never completed. Decision 3's "expiry" covers only the
  witness step, so the row stayed in the open set, kept `complete` reachable for ever, and — with
  decision 7's one-open-request rule — stopped that parent from ever asking again.
- **`witnessRef` could not be filled for the device witness.** Decision 8 defines `witnessRef` as "the
  device id or the approving parent's id". One `show_reset_code` code goes to *every* paired device of
  the family (decision 2.3), so no single device is the witness; the implementation stores `null` and
  decision 8 as written says otherwise.
- **A parent whose request could not be completed on the device side hit a dead end.** Reaching the
  child's phone inside the code's 10 minutes can fail — the phone is at school, the child is asleep, the
  app is not showing the notice. The request then sat in `mailbox_confirmed` and `request` answered
  `409 reset_already_pending` until the 24-hour sweep closed it. The parent had already spent one of
  decision 7's three attempts per 30 days and had to wait most of a day to spend a second one.
- **Already true in the code, unrecorded here:** `/login` cancelling an open request also clears that
  request's `show_reset_code` payloads (merged in #305 at `384a188`,
  `services/api/src/routes/auth.ts:275`). A code for a dead request must not keep showing on the child's
  phone for its remaining minutes.

### Decision

1. **A `witness_passed` request that is never completed expires seven days after `windowEndsAt`.** The
   expiry job (`services/api/src/jobs/mfaResetExpiry.ts`) sweeps `state = 'witness_passed' AND
   windowEndsAt <= now - 7 days` to `state = 'expired'` with `outcomeAt = now`. Seven days covers a week
   away after the window; after that the parent starts again with a fresh witness.
2. **`witnessRef` stays `null` for a device witness.** This amends decision 8: `witnessRef` is the
   approving parent's id for a `parent` witness, and `null` for a `device` witness, because one code goes
   to every paired device and no single device can be named. `witnessKind` is what distinguishes the two.
3. **`request` supersedes the parent's own open request when it is `requested` or `mailbox_confirmed`.**
   The old row is marked `expired` with `outcomeAt = now`, and its `show_reset_code` payloads are cleared
   through `clearResetCodePayloads(requestId)`, and the new request is created as normal. A
   `witness_passed` request still blocks with `409 reset_already_pending`: a window a co-parent has
   already approved is not restartable. The three-requests-per-30-days count of decision 7 is unchanged —
   superseded rows still count, so this grants no extra attempts. A request that the limit is about to
   refuse does not supersede anything first.
4. **Recorded, not changed:** `/login` cancelling a request clears that request's `show_reset_code`
   payloads (#305, `384a188`).

### Why

- **Seven days, not the 72 hours.** The window is the wait the parent owes the real parent to notice;
  the grace is the wait the *routine* owes the parent who was travelling, ill or simply did not come
  back. Expiring at `windowEndsAt` would punish an ordinary week away for no security gain — the
  witness step is still required, and the sign-in cancel still kills a live request. Expiring never
  would leave decision 7's open-request rule with no way out but support, which this ADR does not have.
- **`witnessRef` null for a device witness is the honest value.** Naming one of several devices would
  be a false record for an audit row that only exists so a parent and the family's owner can read what
  happened.
- **Supersede, not a longer refusal.** The parent cannot complete the request because the child's phone
  is not reachable, which is exactly the case decision 2.3's 10-minute code does not survive. Answering
  `reset_already_pending` for the remaining 23 hours turns one failed attempt into a day of lockout, and
  the parent has no way to cancel from their side: they cannot sign in (that is why they are here) and
  the cancel link is in an email they may not have opened. Superseding keeps the accounting honest: the
  attempt is still counted, and the visible record shows the abandoned request as `expired`.
- **`witness_passed` staying closed is the safety half.** A passed witness revoked every session and
  opened a window that every other parent was told about. Letting a second `request` quietly replace it
  would let an attacker who lost the race restart the clock without the family noticing.

### Falsifiable claims

1. **The 7-day expiry exists and is bounded.** After the expiry job runs with `now` such that a
   `witness_passed` row's `windowEndsAt` is 8 days old, that row is `expired` with `outcomeAt` set; at 6
   days it is still `witness_passed` with `outcomeAt` null. `complete` on the expired row answers
   `409 request_expired`.
2. **A device witness stores no device id.** A request passed with the child device's code has
   `witnessKind = 'device'` and `witnessRef = null`; one approved by a co-parent has `witnessKind =
   'parent'` and `witnessRef` equal to that parent's id.
3. **A `mailbox_confirmed` request can be replaced.** A second `request` for the same parent answers
   `200`, the first row is `expired` with `outcomeAt` set, no `show_reset_code` row for the first request
   keeps a `code` in its payload, and the first request's confirm link no longer opens it.
4. **A `witness_passed` request cannot be replaced.** A second `request` answers `409
   reset_already_pending`, and the `witness_passed` row's state, `outcomeAt` and `windowEndsAt` are
   unchanged.
5. **A supersede grants no extra attempts.** Three requests inside 30 days, superseded or not, leave the
   fourth answering `429 reset_limit_reached`, with three rows for that parent and no row superseded by
   the refused request.
6. **A cancelled request keeps no live code.** After a successful `/login` cancels an open request, no
   `show_reset_code` payload for it carries a `code`.

### What this amendment does not do

- It does not touch decision 2's factors, decision 3's 24-hour witness deadline, decision 5's recovery
  sequence, decision 6's `no_witness` refusal or decision 7's three-per-30-days ceiling.
- It does not add the read-only audit route (decision 8) or the notification templates (decision 4).
  Those remain unbuilt, as the changelog fragment for #305 states.

