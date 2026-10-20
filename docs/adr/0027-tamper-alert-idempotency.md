# ADR-0027 — Tamper alerts are edge-triggered and idempotent

- **Status:** accepted
- **Date:** 2026-10-20
- **Deciders:** Kimi Code (development lead), implementing #225 from Claude's Flip4 verification of #224
- **Related:** #224 (the verification run), #225 (both findings), ADR-0010 §4 (admin removal reaches
  the parent), `GuardianAdminReceiver`, `TamperAlertWorker`, `AccessibilityOffReceiver`,
  `services/api/src/lib/alerts.ts`, migration `0019_alert_dedupe_key`

## Context

Two defects were measured on the Flip4 while verifying #224. Both page the parent about a state the
device was either never in, or already reported.

1. **One deactivation, two `device_admin_removed` alerts.** `GuardianAdminReceiver.onDisabled` sets
   `admin_disabled_pending` and enqueues an expedited `TamperAlertWorker`. The 60-second loop in
   `LocationService` enqueues the same work again when it sees the pending flag or a tier drop to
   `NONE` (`deviceAdminCheckOnce`). The first worker posts and clears the flag; the second enqueued
   work still runs and posts a second alert. Both runs are correct in isolation — the bug is that
   nothing names the *event*, so neither can tell it has already been reported.
2. **A false "accessibility service was turned off" on a fresh install.** `AccessibilityOffReceiver`
   polls `Settings.Secure` and alerts whenever the service is not effectively enabled. During setup,
   before the parent has granted accessibility, that is the normal state, so the first poll after
   pairing paged the parent about a protection they never had.

The paging channel is the product's trust surface: a duplicate page at 2 a.m., or a "service turned
off" on an untouched install, makes every later alert suspect.

## Decision

1. **The admin-removal alert carries an idempotency key.** `onDisabled` records the disable
   timestamp (`TamperState.adminDisabledAtMs`); the alert key is
   `<deviceId>|<type>|<disabledAtMs>` (`TamperAlertDedupe.adminRemovalKey`). Both enqueue paths pass
   the same timestamp to the worker, and a worker that has already recorded the key skips the POST.
   `admin_disabled_pending` is cleared only after a successful post (or a confirmed duplicate), never
   on failure, so an offline device still retries.
2. **The server enforces the same rule.** `Alert.dedupeKey` is a nullable column with a **partial**
   unique index on `(deviceId, category, dedupeKey) WHERE dedupeKey IS NOT NULL`. A duplicate insert
   returns the existing row, publishes no second realtime event and sends no second push; the
   internal route answers `200` instead of `201`. Alerts without a key keep the old best-effort
   behaviour, so no other producer changes.
3. **The accessibility alert is edge-triggered.** The agent persists the last observation
   (`AgentSettings.accessibilityWasEnabled`). The alert is raised only when that record is `true` and
   the service is off now; a first observation that it is off — `null` — is silent. A failed POST
   leaves `true` recorded, so the next poll retries; while it stays off after a successful (or
   throttled) report, the recorded state is `false` and nothing repeats.

## Alternatives rejected

- **Drop the 60-second drain and trust only the expedited worker.** The drain is the documented
  backstop when the process dies after `onDisabled` (ADR-0010 §4). Deleting it would trade a
  duplicate page for a lost one.
- **Server-side time-window throttling per type (e.g. ignore repeats within 60 s).** It picks an
  arbitrary window, suppresses a genuine second event inside it, and leaves the client posting into
  a hole. An explicit event key is exact and testable.
- **Keep the accessibility check level-triggered and suppress the first check after install with a
  time delay.** A delay is a guess about setup length; the recorded transition state is the fact the
  product actually means.
- **A unique index on `(deviceId, category)` only.** That would collapse a second, genuine removal
  forever. The timestamp is what distinguishes events.

## Consequences

- Two workers racing past the client check are resolved by the DB index; the loser answers `200` and
  does not push. The parent sees exactly one row and one push.
- `Alert.dedupeKey` is additive and nullable. A pre-#225 API binary ignores the column, and a
  pre-#225 agent sends no key, so a staged deploy is safe in either order.
- The key set in `TamperState` is bounded (four entries) because only the newest retry matters; an
  ancient key falling out can at worst allow a duplicate POST, which the server index then absorbs.
- The first accessibility observation after a re-pair is a first observation again (`clearPairing`
  removes the recorded state), so a re-paired device with accessibility still off stays silent until
  it is enabled and then disabled.
- Cost: one more DataStore write per 60-second poll and one `findFirst` per keyed alert. Both are
  negligible beside the POST they guard.
