# ADR-0029 — Repeated remove-protection attempts are one counted alert per five-minute window

- **Status:** proposed
- **Date:** 2026-10-20
- **Deciders:** Kimi Code (development lead), implementing #227 from Claude's finding while verifying
  PR #226
- **Related:** #227 (the defect), #225 / ADR-0027 (the per-event dedupe key this rule complements),
  ADR-0010 §4 (tamper alerts reach the parent), `AccessibilityMonitorService.guardProtectionScreens`,
  `TamperAlertWorker`, `TamperAlertDedupe`, `services/api/src/lib/alerts.ts`, migration
  `0021_alert_attempt_count`

## Context

With the accessibility service active, every attempt by the child to open the **admin-removal
screen** posts its own critical alert. Measured by Claude on the Flip4 (reported in #227): five
attempts about 10 s apart produced **five critical pages**. The alert type is
`protection_screen_opened` (`TamperAlertWorker.TYPE_GUARD_TRIGGERED`).

The mechanism is direct:

- `AccessibilityMonitorService.guardProtectionScreens` intercepts the OS screen and calls
  `TamperAlertWorker.enqueue(this, TYPE_GUARD_TRIGGERED, …)` on every guard
  (`apps/child-android/.../AccessibilityMonitorService.kt:332`).
- `TamperAlertWorker` attaches a dedupe key only to `device_admin_removed`
  (`TamperAlertWorker.kt:43-49`), so every guard run POSTs.
- `AlertThrottlePolicy` collapses repeats of a **detection type**, but only the alert sites that
  call it do so: `AccessibilityOffReceiver.kt:42`, `LocationService.kt:363,387,432`. The guard path
  never calls it, which is why "the per-type throttle does not collapse them". Raising its window
  would not help anyway: a one-hour silence would also hide a genuine second removal attempt.

The paging channel is the trust surface. Five pages for one child poking at Settings trains the
parent to ignore the tamper alert — the same failure #225 fixed for one deactivation.

## Decision

**Option (a): one alert row per window, updated in place with the current attempt count.**

1. **Agent window.** A pure rule (`security.GuardAttemptWindow`) keeps a persisted
   `(windowStartMs, count)` per device enrolment with a **5-minute** window, matching #227. The first
   attempt opens the window at count 1 and is enqueued **immediately** — a parent hears about attempt
   1 now, not at the end of the window. Each further attempt inside the window increments the count
   and enqueues an update. An attempt **exactly at** `windowStart + 5 min` belongs to the new window.
   The window is keyed only on the persisted start time and count: taking the guard overlay down and
   reopening the removal screen cannot reset it, because visibility is something the child controls.
   A re-pair clears the window (`AgentSettings.clearPairing`), so a new device enrolment starts fresh.
2. **Wire contract.** The worker sends
   `dedupeKey = "<deviceId>|protection_screen_opened|<windowStartMs>"` plus the top-level
   `attemptCount`. This is the aggregate identity; the count is data on that identity, not part of
   it (a count in the key would create a row per attempt).
3. **Server.** `raiseAlertOnce` keeps the #225 path exactly as it is when `attemptCount` is absent: a
   repeat key returns the existing row and does nothing else. When `attemptCount` **is** present and
   higher than the stored `Alert.attemptCount`, the same row is updated (`attemptCount`, `body`,
   `metadata`) and a realtime `alert` event is published so an open parent list refreshes. The parent
   is **not** pushed again. The update is conditional on the stored count being lower, so two
   aggregate POSTs that race cannot let the lower count overwrite the higher one; a lower or equal
   count is a retry and changes nothing. The route still answers `200` for a repeat; a new window
   inserts a row and answers `201`.
4. **Lost POST.** The count is persisted **before** the POST, and the client-side idempotency key
   (`<aggregateKey>|<count>`) is recorded **only after** the POST succeeds, mirroring
   `TamperAlertDispatcher`. A failed POST leaves the key unrecorded, so WorkManager retries it; if a
   new attempt arrives first, its cumulative count includes the unsuccessful one and replaces the
   retry (`ExistingWorkPolicy.REPLACE`). The count therefore never resets on failure.

## Alternatives rejected

- **Option (b): one alert with the count in `metadata`, plus a closing notification when the window
  ends.** The closing notification re-pages after the fact, and a parent who dismissed the first page
  is paged again for the same event. It also delays the count reaching the parent. Rejected for a
  safety alert: quiet and honest beats re-notifying.
- **Widen `AlertThrottlePolicy` to cover the guard path.** It is a per-type timestamp, not an
  aggregate: it would suppress attempt 2 silently for an hour and lose the count entirely.
- **Key the window on the guard screen becoming visible, or reset it when the screen closes.** The
  child controls that transition; retrying would produce a new window and a new page every time.
- **Batch attempts client-side and POST once when the window closes.** It avoids a POST per attempt
  but delays the first page by up to five minutes, which breaks the product promise that tamper
  alerts reach the parent within seconds.
- **Put the count in the dedupe key.** Every attempt would then be a new key and a new row — the
  defect again.
- **A server-side time-window throttle.** Rejected in ADR-0027 for the same reason: the server cannot
  tell a retry from a genuine second event, and an arbitrary server window leaves the agent posting
  into a hole.

## Consequences

- Five attempts in five minutes produce **one row whose body says "5 attempts"** and **one push**.
  The parent can see escalation by opening the card; the history keeps the first attempt's
  `createdAt` and the final count.
- Cost, deliberate: individual attempt times are not retained — the row keeps a count, not a list.
  If a future reviewer needs per-attempt audit, that is a new decision (a child table), not a change
  to this rule.
- Cost: one signed POST and one row update per attempt inside the window (no push). A poking child
  creates up to ~one request per guard event; the accessibility guard already debounces at 1.5 s
  (`AccessibilityMonitorService.kt:301`), and a POST is far cheaper than a page.
- The server update path is additive: a pre-#227 API binary ignores `attemptCount`, and a pre-#227
  agent sends none, so a staged deploy behaves as before (one row per attempt on the old agent).
- A clock moved **forward** ends the window early and lets the next attempt open a new row (a new
  page); a clock moved **backward** keeps incrementing the current window. Neither can silence the
  alert, which is the property that matters for a tamper signal.
- `Alert.attemptCount` defaults to 1 for every existing row and producer, so no backfill is needed
  and no other alert type changes shape.
- The #225 contract is untouched: `device_admin_removed` still carries its event key, still produces
  one row, still answers `200` on retry, and still pushes once.

## Evidence

- JVM: `GuardAttemptWindowTest` — five attempts → one window/count 5; crossing the boundary → new
  window count 1; exactly at the boundary → new window; first attempt at count 1 immediately; a
  failed POST at attempt 2 leaves attempt 3 at count 3; a retried POST of the same count posts once.
- API: `alerts.test.ts` — repeat key updates the row's `attemptCount` with one `create` and no push;
  a new window key creates a row with `attemptCount` 1; an out-of-order lower count does not lower;
  the #225 duplicate and unique-collision tests are unchanged.

**⚠️ Not verified here:** no physical phone and no live stack in this run — the five-attempts →
one-page row on hardware remains to be re-run by the testing lane.
