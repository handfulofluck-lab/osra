# ADR-0023 — MFA recovery: one-time recovery codes at enrolment, with a support break-glass for the cohort that has none

- **Status:** proposed — for ratification by the KCL lead (architecture)
- **Date:** 2026-10-18
- **Deciders:** Claude (KCL lead); proposed by Kimi Code (development lead), from the recovery gap left
  open by #139 in issue #136
- **Related:** ADR-0004 (optional MFA and session hygiene), ADR-0014 (MFA secret at rest), ADR-0013
  (retention and erasure); issues #136, #139

## Context

MFA is optional and off by default (ADR-0004). When a parent enables it, the current API has three
documented properties, and a fourth that nobody designed:

1. **Login demands a TOTP.** `POST /v1/auth/login` returns `401 {"error":"mfa_required"}` when
   `Parent.mfaEnabled` and the body has no valid current code (`services/api/src/routes/auth.ts:166-180`,
   the check at `:174-180`; replay protection in `verifyTotpFresh`, `:46-73`).
2. **A replacement secret needs proof.** `POST /v1/auth/mfa/enroll` replaces an existing
   `Parent.mfaSecret` only when the body carries the account password (`argon2.verify`) or a current
   TOTP (`:218-254`, re-auth `:230-245`, write `:247-253`); a first enrolment — no secret yet — still
   accepts only the session token, so onboarding is unchanged (#139).
3. **A password reset does not clear MFA.** `POST /v1/auth/reset/confirm` writes `passwordHash` and
   nothing else (`:289-310`, the update `:300-302`), then revokes sessions. This is deliberate: email
   is the weakest link, and clearing the second factor on an email click would make mailbox compromise
   a complete account takeover.

`Parent` has `mfaEnabled` and `mfaSecret` and nothing else on this axis
(`services/api/prisma/schema.prisma:38-53`, fields `:47-48`); the secret is encrypted at rest as
`enc1:<vault json>` under `VAULT_KEY` (`services/api/src/lib/secretVault.ts:8-13`, ADR-0014). There is
no recovery-code table, no admin/support route (`services/api/src/routes/` contains only parent- and
device-facing surfaces), and no support role in the data model. The account/session contract lives in
`docs/SPEC-ADDENDUM-WORLD-CLASS.md:77-98`; `docs/SPEC.md` still describes `src/routes/auth.ts` as a
skeleton with MFA/reset TODOs (`:123`) and has no account-recovery section — the implementing PR should
add one, because this ADR records the decision but not the user-facing procedure.

The parent app has a "Authentication code" field on login
(`apps/parent-app/lib/features/auth/login_screen.dart:129-136`, wired in
`apps/parent-app/lib/providers/auth_provider.dart:81-86`), but **no MFA enrolment screen and no
recovery screen** (`apps/parent-app/lib/features/settings/` contains only digest preferences). MFA can
be enabled only by calling the API directly. That is the first honest cost in this ADR: the recovery
mechanism is only reachable by users once the client has an enrolment screen that displays the codes.

### What a parent does today after losing the authenticator

| Situation | Today |
|---|---|
| A **live session** still exists on another device (access token ≤ 7 days, or a refresh token) | `POST /v1/auth/mfa/enroll` with the password → new secret → `POST /v1/auth/mfa/verify` → sessions are revoked and the next login uses the new authenticator. This is the only supported path, and losing the phone usually loses the session with it. |
| **No live session**, authenticator gone | Locked out. Login needs a TOTP they cannot produce; `/mfa/enroll` needs a session *and* (because a secret exists) a password or TOTP they cannot fully provide; a password reset changes the password but login still returns `401 mfa_required`; the app has no reset screen either. |
| **Contact support** | There is nothing to contact. No support role, no admin route, no audit table, no documented identity-check procedure. |
| **Use the password-reset flow** (not in any client) | **Works today, and it is a full takeover.** A reset token is signed with the same `JWT_SECRET` (`auth.ts:280-283`) and `requireJwt` checks only the signature and session liveness (`:204-216`; `isParentSessionLive` in `services/api/src/lib/sessions.ts:53-68` does not inspect claims). An attacker with **mailbox access only** can: request a reset link, confirm it with a password of their choosing, request a second link (minted after the epoch moved, so it is live), then present that token to `/mfa/enroll` with the new password. The re-auth branch accepts the password (`:230-245`), the secret is replaced (`:247-253`), `/mfa/verify` enables it, and login succeeds. Verified live on a disposable account — every step 2xx, final login with the attacker's password and TOTP `200` (see Evidence). No client implements this, so a parent still cannot use it; an attacker can. |

**Answer to the question "is the current design right and only documentation missing?": no.** It is
not right, and this is not a documentation gap. It leaves a real lockout, and it *already* delivers
Option C's outcome through the purpose gap: mailbox control alone replaces MFA on a live account.
The rule "a password reset does not clear MFA" is true at `/reset/confirm` and false in effect.
Documentation cannot fix that; the purpose check has to land, and a safe recovery path has to be
added. The purpose check is urgent on its own and should not wait for the recovery feature.

## Decision

If accepted, ADR-0023 decides the following. **No code is written under this ADR**; the implementation
is a separate work item with its own PR, tests and probe checks.

1. **Recovery codes are the primary recovery mechanism.** Ten single-use codes, 16 Crockford base32
   characters each (80 bits), displayed once, stored only as SHA-256 hashes, issued when MFA is enabled
   (and re-issued when the secret is replaced).
2. **Recovery resets the second factor, it does not log the parent in.** `POST /v1/auth/mfa/recover`
   takes `{email, password, code}` and returns a 15-minute, purpose-scoped token (`purpose:
   "mfa_recovery"`, no `familyId`, no `role`) that only the MFA enrolment routes accept. Recovery clears
   `mfaSecret`/`mfaEnabled`, consumes the code, deletes the remaining codes, revokes every session and
   sends a notification email. The parent must enrol a new authenticator and verify it before a normal
   session is issued again.
3. **The recovery token is not a session and cannot read family data.** It is accepted by
   `POST /v1/auth/mfa/enroll` and `POST /v1/auth/mfa/verify` only while `mfaEnabled === false`; every
   other route rejects it. This bounds the password-only window between recovery and re-enrolment.
4. **`requireJwt` becomes purpose-aware.** It requires `role === "parent"` and rejects any token that
   carries a `purpose` claim; a separate `requireParentOrMfaRecovery` accepts `purpose:
   "mfa_recovery"` on the two enrol/verify routes only. This is the prerequisite that closes the
   reset-token takeover above, and it completes the part of issue #136's acceptance line that #139 did
   not land. It should land as its own small fix, before and independently of the recovery feature.
5. **Password reset continues not to clear MFA.** Option C below is rejected; this ADR does not
   supersede ADR-0004's "optional MFA" clause or ADR-0014's secret-at-rest rule.
6. **The existing locked-out cohort needs Option B, and that is the maintainer's call.** Codes cannot be
   backfilled: a parent who enabled MFA before this ships has none, and a parent already locked out
   cannot generate them. Until they log in and regenerate, their only path is a support-assisted,
   identity-checked reset — a product and staffing decision this ADR cannot make for the maintainer
   (see "Decision ownership").

## Reasoning

- **Recovery codes are the only self-service option that does not weaken the second factor.** They are
  a second factor the parent physically holds, generated at the same moment as the TOTP secret, and
  they survive the loss of the authenticator without making the mailbox sufficient on its own: the
  recovery request also requires the password.
- **They fit the existing trust model.** No new party, no new credential authority, no support
  staffing. Storage is a new table with hashes; the code is random, so a fast hash is appropriate and
  argon2 would only add latency to a rate-limited lookup. 80 bits keeps offline guessing infeasible
  even if the table leaks, which 10-character (50-bit) codes would not.
- **Clearing MFA on recovery is the honest state.** The old secret is presumed lost; keeping it enabled
  would leave the account unusable. The restricted token means the account is password-only only for
  the length of one enrolment, and no family data is reachable in that window.
- **One-time use must be transactional.** `updateMany({ where: { id, usedAt: null } })` returning
  `count === 1` is the gate; two concurrent requests with the same code cannot both win. Deleting the
  remaining codes on success bounds a stolen list to a single use and avoids leaving valid credentials
  behind after a lost-device event.
- **Doing nothing is not neutral.** It keeps the lockout and preserves an accidental email-based
  recovery that we would never design on purpose.

## Alternatives considered

### Option A — recovery codes generated at enrolment (recommended)

Ten codes, shown once, hashed at rest, one-time, cleared on use, regenerated with password or current
TOTP. Endpoints and tests below.

- **Cost:** one migration, one table, four route changes (two new, two extended), one email template,
  one Flutter settings screen and a login recovery path. No new dependency, no new staff.
- **Residual risk:** a stolen code list plus the password is an account takeover — the same as a stolen
  authenticator, mitigated but not eliminated by hashing, one-time use and the notification email. A
  parent who loses both the authenticator and the codes is still locked out until Option B exists.
- **Why recommended:** it closes the gap for every parent who enrols after it ships, without making
  email compromise sufficient.

### Option B — time-boxed, support-assisted reset with an audited identity check

A parent (or someone claiming to be one) requests a reset; the account email is notified immediately;
a cooling-off period (suggested 48–72 h) with a cancel link passes; a support operator performs a
documented identity check, then clears MFA, forces a password change and notifies every parent in the
family. Every step is written to an append-only audit record.

- **What it needs:** a support/admin identity that is not a parent JWT, an admin route surface, an
  append-only `SupportAction` table (who, when, which account, what evidence, ticket id), a runbook
  defining what counts as proof of identity, a notification and cancellation flow, data-retention and
  privacy review for the identity evidence, and a human with the time to run it. None of that exists
  today.
- **Strength:** it is the only option that helps the already-locked-out cohort (including anyone who
  loses both the authenticator and the codes), and the cooling-off plus notification makes a social
  engineering attempt visible and cancellable.
- **Weakness:** identity checks are a judgement call; a convincing impersonator can still win, and the
  cost is ongoing human time rather than a one-off build. It is not a "purely technical" change.
- **Verdict:** recommended as the break-glass path, **deferred to the maintainer** because it commits
  the product to staffing and a policy, not just code.

### Option C — clear MFA on a verified email reset

Add `mfaEnabled: false, mfaSecret: null` (and delete recovery codes) to `/reset/confirm`.

- **The takeover risk, spelled out:** anyone who controls the mailbox — a shared family inbox, a
  recycled address, a compromised password manager, a support desk that resets the mailbox on request —
  becomes the account. They request a reset, click the link, set a password, and the second factor is
  gone; they then read the family's location and content data and control the child's device. The
  second factor exists precisely to survive mailbox compromise, so this converts the strongest control
  into the weakest one.
- **Minimum safeguards if the maintainer overrides:** single-use reset tokens (today a 15-minute token
  is reusable), a 48–72 h delay with cancellation and notification, forced re-enrolment before any
  family route, and an audit record. With all of those it is Option B with a weaker identity check
  (email control) and no human review — safer than the naive version, still weaker than B.
- **It is already the de facto behaviour.** The purpose gap above lets mailbox control replace MFA
  today, without the delay, the notification or the forced re-enrolment. Rejecting Option C therefore
  requires closing that gap; otherwise the product has C's risk without C's safeguards.
- **Verdict:** rejected.

### Option D — keep the current design and document the lockout

Document "if you lose the authenticator, you are locked out unless you still have a session".

- **Verdict:** rejected. It does not remove the accidental reset-token path (which is Option C reached
  through a bug), and a consumer parental-control product cannot ship a setting that can permanently
  strand the account holder.

## Consequences

**Good**

- A parent who loses the authenticator can recover with something they were told to keep, without a
  mailbox-only path and without support.
- The second factor is never silently downgraded to "email control"; recovery requires password plus
  code.
- Every recovery is visible: email notification, all sessions revoked, old codes deleted.
- The purpose check closes a live email-only takeover (a reset token is accepted as an access token)
  independently of the recovery feature.

**Bad / costs**

- **Migration cost:** new table `ParentMfaRecoveryCode`, one migration
  (`0016_parent_mfa_recovery_codes`), index on `(parentId, usedAt)`, FK `onDelete: Cascade`. No
  backfill is possible — codes cannot be derived from the TOTP secret, and a parent already locked out
  cannot create them. Existing MFA users must regenerate while logged in; a parent who has already lost
  the authenticator is not helped by Option A at all.
- **Client cost:** the parent app has no MFA screen. Shipping the API alone changes nothing for a
  normal user; the Flutter screen (enrol, show codes once, "I saved them", recovery code on login,
  forced re-enrolment after recovery) is part of the work, not an optional follow-up.
- **Support copy:** the recovery email must not promise a support channel that does not exist. Until
  Option B is decided, it states what happened and that every session was revoked, and tells the
  account owner to change the password; it offers no link that leads nowhere.
- **Probe cost:** new checks and a new count in `qa-probe.mjs`; `check-probe-integrity.mjs` must show
  additions, not removals.
- **The old secret is gone after recovery.** A parent who finds the old authenticator later cannot use
  it; that is intentional.

**Residual risk (named)**

- Password + a stolen code list = takeover. Hashing at rest, one-time use, delete-all-on-use and the
  notification email reduce the window; they do not remove the risk.
- Lost authenticator **and** lost codes = still locked out until Option B exists.
- The password is the floor: a weak or reused password plus one leaked code is enough. Enrolment already
  requires 12 characters, but strength is not measured.
- A code is a bearer secret in the user's hands; screenshots, clipboard history and cloud notes are
  outside our control.
- If the user dismisses the one-time display, they must regenerate while logged in; there is no "show
  again".
- The purpose check must land before the recovery routes. If it does not, a reset token remains a
  bearer token and the email-only takeover survives alongside the new mechanism.

## Implementation sketch (not implemented here)

### Data model

```prisma
model ParentMfaRecoveryCode {
  id        String    @id @default(uuid())
  parentId  String
  codeHash  String    // sha256(normalised code); never the plaintext
  createdAt DateTime  @default(now())
  usedAt    DateTime?
  parent    Parent    @relation(fields: [parentId], references: [id], onDelete: Cascade)

  @@index([parentId, usedAt])
}
```

Add `mfaRecoveryCodes ParentMfaRecoveryCode[]` to `Parent`. The FK cascade covers account/family
deletion; `/family/me` and `/family/export` (`services/api/src/routes/family.ts:40,44-54,266-288`) must
not select the relation, and a test should assert no `codeHash` appears in either response.

Code format: Crockford base32 (no `I`, `L`, `O`, `U`), 16 characters = 80 bits, displayed
`XXXX-XXXX-XXXX-XXXX`. Normalise before hashing: uppercase, strip spaces and hyphens. Hash with SHA-256
(the value is uniformly random; password stretching is not relevant and would make a 10-row lookup
slow). Never log the plaintext and never return it after the issuing response.

### Endpoints

| Endpoint | Auth | Request | Success | Failure | State change |
|---|---|---|---|---|---|
| `POST /v1/auth/mfa/enroll` (extended) | parent access token, or `mfa_recovery` token while `mfaEnabled=false` | unchanged `{password?, code?}` | unchanged `{secret, otpauthUrl}` | `401 unauthorized` / `401 reauth_required` | on a replacement, delete the existing code rows — they belong to the old secret; new codes are issued by `/mfa/verify`. A recovery token may replace an unverified secret because MFA is off |
| `POST /v1/auth/mfa/verify` (extended) | same | `{code}` | `{ok: true, mfaEnabled: true, recoveryCodes: string[], recoveryCodesIssuedAt}` | `400 mfa_not_enrolled` / `401 invalid_code` | in one transaction: `mfaEnabled=true`, delete old code rows, insert 10 hashes; then revoke all refresh tokens and bump the session epoch (existing `revokeAllRefreshTokens`) |
| `POST /v1/auth/mfa/recover` (new) | none; auth rate limit 20/min | `{email, password, code}` | `{recoveryToken}` (15 min, `{sub, purpose:"mfa_recovery"}`, no `familyId`/`role`) | `401 {"error":"invalid_recovery"}` for unknown email, wrong password, wrong/used code, or MFA not enabled; `429` | transaction: `updateMany({where:{id,usedAt:null}})` must return 1, delete remaining codes, `mfaEnabled=false`, `mfaSecret=null`; then revoke all sessions; send a security email |
| `POST /v1/auth/mfa/recovery-codes/regenerate` (new) | parent access token | `{password?, code?}` | `{recoveryCodes, recoveryCodesIssuedAt}` | `401 reauth_required` | delete old rows, insert 10 new hashes (same re-auth helper as enrol) |
| `POST /v1/auth/login` | unchanged | unchanged | unchanged | unchanged | unchanged |

`recoveryToken` is stored in Redis as `mfa:recovery:<jti>` → parentId with a 15-minute TTL and deleted
when `/mfa/verify` succeeds. If the store is unreachable in production, reject the token (fail closed),
consistent with the other session checks.

Failure responses on `/mfa/recover` are deliberately indistinguishable so the endpoint does not reveal
whether an address is registered or has MFA. Run `argon2.verify` against a dummy hash for unknown
emails so timing does not leak either. The generic 401 is also why the UI says "email, password or
recovery code is incorrect", not which one.

### Tests (must fail before, pass after)

`services/api/test/auth.test.ts` (or a new `test/mfa-recovery.test.ts` if the file grows past
readability):

1. Enrol + verify returns 10 distinct `XXXX-XXXX-XXXX-XXXX` codes; the mock sees 10 `createMany` rows
   whose `codeHash` values are 64 hex characters and none of the plaintext (fails now: field absent).
2. `recover` with the correct email, password and code returns a `recoveryToken`, clears
   `mfaSecret`/`mfaEnabled`, marks the code used, deletes the other nine, and calls
   `invalidateSessionsBefore` / `revokeAllRefreshTokens` (fails now: 404).
3. The same code is rejected the second time (one-time use), including two concurrent requests where
   only one `updateMany` returns 1.
4. A successful recovery invalidates the remaining nine codes (use a second one → `401
   invalid_recovery`).
5. Unknown email, wrong password, wrong code and a non-MFA account all return the same
   `401 invalid_recovery` and write nothing (no enumeration).
6. The `mfa_recovery` token is accepted by `/mfa/enroll` + `/mfa/verify`, refused by `/family/me`
   (`401`/`403`), and refused after `mfaEnabled` becomes true.
7. A fresh set is issued after re-enrolment; the pre-recovery hashes are gone.
8. `recovery-codes/regenerate` requires password or current TOTP; a new set replaces the old and old
   codes fail.
9. **Purpose check:** a token `{sub, purpose:"password_reset"}` gets `401 unauthorized` on
   `/mfa/enroll` and `/mfa/recovery-codes/regenerate`; a device token and a token without
   `role:"parent"` are refused too. (Fails on today's code: the reset-purpose token reaches the
   handler — see Evidence.)
10. Login after a password reset still returns `401 mfa_required` without a code (pins the rejection of
    Option C).
11. `/family/me` and `/family/export` contain no `codeHash`/recovery rows.

`services/api/scripts/qa-probe.mjs`: a disposable account exercises enrol → 10 codes → recover →
re-enrol → login, the replay of a used code (`401`), and the purpose-token refusal; the check count in
`check-probe-integrity.mjs --base origin/main` must increase, with zero removals.

`apps/parent-app`: widget tests for the settings screen (codes shown once, "I saved them", copy) and
the login recovery entry (`flutter test`).

## Decision ownership (who has to decide what)

| Item | Owner | Kind |
|---|---|---|
| **Option A** — codes, count 10, 80-bit format, hashed storage, password also required at recovery, delete-all-on-use, forced re-enrolment | KCL lead ratifies as architecture; defaults are engineering choices | **Purely technical** — no new party, no new policy, no staffing, no user data beyond the account's own codes |
| **Option B** — support-assisted reset: identity-check standard, who performs it, cooling-off length, audit retention, privacy/legal basis, staffing and SLA | **Human maintainer** | **Product decision** — commits the product to a human process and to holding identity evidence; not implementable by agents alone |
| **Option C** — clearing MFA on email reset | **Human maintainer**, if they want to override the recommendation | **Product/security trade-off** — the maintainer would be accepting mailbox compromise as account takeover; recommended against |
| **Purpose-aware `requireJwt`** (reject `purpose` tokens, require `role:"parent"`) | KCL lead + development lead | **Purely technical, and a prerequisite** — it closes #136's residual hole regardless of the recovery option chosen |

The sequence if this ADR is ratified: (1) purpose check + tests, (2) recovery-code table and endpoints +
tests, (3) parent-app screens, (4) probe checks, (5) maintainer decides Option B and, if yes, it is
specified in a separate ADR because the identity policy is the decision, not the schema.

## Evidence

- Static, re-read at `origin/main@f2437a97`: `services/api/src/routes/auth.ts:46-73,166-180,204-216,218-254,256-270,272-287,289-310`;
  `services/api/src/lib/sessions.ts:53-68`; `services/api/prisma/schema.prisma:38-53`;
  `services/api/src/lib/secretVault.ts:8-13`; `services/api/src/routes/family.ts:40,44-54,266-288`;
  `apps/parent-app/lib/features/auth/login_screen.dart:129-136`;
  `apps/parent-app/lib/providers/auth_provider.dart:81-86`.
- **Live proof of the takeover**, 2026-10-18, against the shared API at `http://127.0.0.1:3000` (not
  restarted), on a disposable parent `qa-adr0023-1792340969685@example.com`. Reset tokens were signed
  with the environment's `JWT_SECRET` (the same value the emailed link carries), so no email was sent
  and no password was known to the "attacker" before the reset:
  - `POST /v1/auth/register` → 201; `POST /v1/auth/mfa/enroll` (session only) → 200;
    `POST /v1/auth/mfa/verify` (TOTP) → 200, `mfaEnabled: true`; login with password + TOTP → 200.
  - `POST /v1/auth/reset/confirm` with a reset token and a **new** password → 200 (email control alone
    sets the password).
  - second reset token (minted after the epoch moved) → `POST /v1/auth/mfa/enroll` with **no**
    password → **401 `reauth_required`** (the token passed `requireJwt` and reached the re-auth
    branch); with the new password → **200** and a new secret; `/mfa/verify` → **200**;
    `POST /v1/auth/login` with the new password + the new TOTP → **200**. Takeover complete.
  - Control: the same `/mfa/enroll` call with no token → 401 `unauthorized`.
  - **Cleanup:** `cleanup-test-data.sql -v apply=1` → `OK: 1 family — demo family only`, demo family
    intact, `select count(*) ... like 'qa-adr0023-%'` → **0**; Redis `refresh:index`,
    `auth:invalid-before` and `mfa:lastcounter` for the disposable parent deleted (3 keys).
- Earlier, a token for a **non-existent** parent id with `purpose:"password_reset"` returned **404
  `parent_not_found`** on the same route (not 401), independently confirming that `requireJwt` accepts
  purpose tokens without touching an account.
- No code was written for this ADR. No fail-before test can exist yet; the tests above are the
  specification for the implementing PR.
- This ADR does not mark #136 resolved. #136's code half is #139; the question it left open — what a
  parent does after losing the authenticator — is what this ADR answers.
