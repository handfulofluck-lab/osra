# ADR-0008 — Parental Consent Lifecycle, Revocation, and Enforcement

- **Status:** accepted
- **Date:** 2026-10-16
- **Supersedes:** Closes the tracked "Known gap" in [ADR-0002](0002-server-authority-and-consent-gate.md)

## Context

Under COPPA (16 CFR Part 312) and GDPR-K (GDPR Article 8), verifiable parental consent (VPC) is not a one-time static event. A parent has the legal right to revoke or withdraw consent at any time, and consent may expire.

ADR-0002 established that creating a child without verifiable parental consent returns HTTP 428 Precondition Required. However, once created, consent records were never queried on subsequent mutations, `ConsentRecord.revokedAt` and `ConsentRecord.expiresAt` were never checked, and there was no endpoint allowing a parent to withdraw consent (tracked under probe target `J3` / Issue #43).

## Decision

1. **One revocation endpoint, next to the grant**: `POST /v1/family/children/:id/consent/revoke` sets
   `revokedAt = now()` on every active record for the child; `GET /v1/family/children/:id/consent`
   reports the current status. Family isolation applies (403 on a foreign child). The earlier
   `/v1/consent/*` alias was dropped before merge: two routes for one action doubles the surface
   the probe and the clients have to track.
2. **Revocation stops processing, not only configuration.** Three layers, all answering
   **HTTP 428 Precondition Required** (`{ error: "parental_consent_required" | "consent_jurisdiction_mismatch" }`)
   while no active (non-revoked, non-expired, jurisdiction-matching) `ConsentRecord` exists:
   - **2a. Parent configuration writes** (`requireConsent` middleware): `PUT|PATCH /v1/rules/:childId`,
     `PATCH /v1/family/children/:id`, `POST /v1/devices/register|pair|pair/claim`,
     `POST /v1/controls/children/:childId/{pause,pause-internet,bonus,wind-down}`,
     `POST /v1/location/geofences`.
   - **2b. Device ingestion and device reads** (`assertProcessingAllowed`): `POST /v1/location/ping`,
     `POST /v1/social/scan`, `POST /v1/alerts/internal`, `POST /v1/content/{search-event,youtube-watch}`,
     `POST /v1/devices/:id/{telemetry,activity}`, and — for a device JWT only — `GET /v1/rules/:childId`
     and `GET /v1/devices/:id/commands`. The parent can still read the dormant ruleset.
   - **2c. Safe-direction actions are never gated**: `resume`, `resume-internet`,
     `POST /v1/devices/:id/command` with `unlock | resume | resume_internet | sos_clear`, and
     `DELETE /v1/family/children/:id` (GDPR Art. 17 erasure). A parent who withdraws consent while the
     internet is paused must be able to un-pause; the opposite would turn a privacy right into a punishment.
3. **Agents are told, then they discover.** Revoke enqueues a `consent_revoked` command to every device of
   the child and publishes a `consent_revoked` family event; re-granting consent (`POST …/consent`)
   enqueues `consent_granted`. The commands are best-effort; the 428 on the agent's next poll is the
   authoritative signal. Agents treat 428 on rules/commands as "pause enforcement and collection, keep
   polling", so monitoring resumes within one poll of a re-grant.
4. **Device pairings survive revocation.** Device JWTs are not revoked on consent withdrawal (that is what
   unpair is for), so re-granting resumes the same pairing without re-enrolling every device.
5. **Jurisdiction**: a record whose `jurisdiction` differs from `Family.region` never satisfies the gate
   (spec §12.5); the grant route already refuses such a record, so this only bites if the family region
   is changed later.

## Reasoning

- COPPA (16 CFR 312.6) and GDPR Art. 7(3) give the parent the right to withdraw consent and require that *collection and use* stop on withdrawal. Gating only the parent's configuration routes — the first draft of this PR — would have left location, chat snippets, telemetry and alerts flowing from the child's device while the parent believed monitoring was off. The review on branch `KCL` (`docs/QA/KCL-2026-10-16/README.md`) caught that inversion; the processing gate (2b) is the fix.
- The 428 answer to the device, rather than a device-JWT revocation, keeps the lifecycle reversible: a parent who revokes on Friday and re-grants on Monday should not have to re-pair three devices.
- Status code 428 Precondition Required clearly signals to integrators and client apps that lawful basis preconditions are missing, distinct from authorization failures (401/403) or syntax errors (400).
- Checking `revokedAt === null` and `expiresAt === null || expiresAt > now()` brings the database schema's temporal tracking columns into active policy enforcement.

## Consequences

- **Positive:** Closes the COPPA/GDPR-K regulatory compliance gap.
- **Positive:** Probe target `J3` is promoted to a green acceptance gate check.
- **Positive:** Tested across all child-scoped mutations, including unit tests and live probe.
- **Negative:** One indexed query (`ConsentRecord(childId, revokedAt)`, migration `0009`) on every device ingestion call and device read. Measured in the probe run at well under a millisecond on Postgres 16; revisit with a short-TTL Redis cache only if ingestion volume makes it visible.
- **Negative:** Agents that do not yet understand 428 will log errors until they are updated; the Android agent handles `consent_revoked`/`consent_granted` and 428 in the same change set, the Windows and iOS agents follow in their own PRs.
- **Rejected alternative — revoke device JWTs on consent withdrawal:** strongest stop, but forces re-pairing on re-grant and conflates two lifecycles (consent vs. enrolment).
- **Rejected alternative — keep the `/v1/consent/*` alias:** no client used it and it doubled the probe surface.

## Evidence

- Gate helpers: `services/api/src/lib/consent.ts` (`checkActiveConsent`, `assertProcessingAllowed`), middleware `services/api/src/middleware/requireConsent.ts`
- Routes: `services/api/src/routes/family.ts` (revoke, status, grant → `consent_granted`), `rules.ts`, `devices.ts`, `controls.ts`, `location.ts`, `social.ts`, `alerts.ts`, `content.ts`
- Migration: `services/api/prisma/migrations/0009_consent_record_index`
- Tests: `services/api/test/consent.test.ts` (20 cases), `services/api/scripts/qa-probe.mjs` checks `J3`, `J3b`, `J3c`, `J3d` — live run 2026-10-16: **77 passed · 0 failed · 2 targets**

## Amendment 2026-10-21 — collection starts when it is allowed (#229)

**Call and SMS logging covers events after the permission is granted; history is never imported.**

Decision 2 says what may be processed while a consent record exists; this amendment fixes *when a
stream starts*. `CommsLogger` used to fall back to a `0L` watermark, so the first harvest after
`READ_CALL_LOG` was granted queried `DATE > 0` and imported the phone's whole call log — 1,986 rows
back to 2026-01-23 in the TR-24 run on the Flip4, including calls made before the app was watching
and before this consent record. The agent now stores `comms_call_since` / `comms_sms_since` and the
matching watermark the first time each permission is seen granted, reads nothing on that harvest,
and floors later reads at the grant time. A withdrawal the agent observes resets both keys, so a
re-grant starts a new window at the re-grant time. The transition is recorded **where the consent flag
flips** (`ConsentState` counts withdrawals and stores the re-grant time), not at the first harvest after
it: a pause shorter than the 5-minute comms loop would otherwise never be recorded, and the resetting
harvest would read nothing — dropping the very row that triggered it. `CommsConsentPolicy.resetTo`
decides when to reset and restarts from the re-grant time. The rule lives in `CommsWatermarkPolicy`
(`apps/child-android/app/src/main/java/com/familyshield/agent/comms/CommsWatermarkPolicy.kt`) with
the harness caveat recorded in `CHANGELOG.md`: the policy is JVM-tested, the permission-flip
lifecycle is source-pinned only.

This is a data-minimisation consequence of decision 1 (revocation stops processing): a grant is the
start of processing, so events from before it are not "already collected" data the parent may see.
It also keeps old numbers out of the #27 unknown-contact alerts. Cost: calls and messages sent before
the grant are unavailable to the parent timeline forever — deliberately, and the parent timeline
says "phone calls" so app calls are not implied.

**Known limit, accepted.** The reset-on-withdrawal runs only when the agent *observes* the
withdrawal; a process dead for the whole withdrawal→re-grant window writes no pause marker, and the
stored `*_since` floor keeps the *old* grant time, so rows from the paused window can be read
afterwards. Closing that needs a consent window the server records and the device asks for, which is
a larger contract than this amendment; it is recorded here rather than left in a code comment.

**Observed 2026-10-21 (Claude's restart row on #257): the limit is narrower than it reads.** The running
agent saw the withdrawal; the process was then killed and restarted while consent was still withdrawn,
and consent was given back afterwards. A paused agent's command poll is answered 428 and drains nothing,
so `consent_revoked` and `consent_granted` both stayed queued and arrived together on the first successful
poll after the re-grant: the new process flipped `ConsentState` paused and active again within 3 ms,
before its first harvest, so the epoch moved anyway. The same delivery is expected when the process is
dead for the whole window, because both commands stay queued until the first successful poll, but that
case was not measured. The persisted epoch is therefore a second line of defence. What remains open is a
device that makes no successful poll between the withdrawal and the re-grant and comes back more than 7
days after the withdrawal: `consent_revoked` has expired by then (`COMMAND_TTL_SECONDS`), only
`consent_granted` arrives, the state never flips, and the old floor can read the paused window.
