# QA-ANDROID — Child Agent QA Report (2026-09-15)

Scope: `apps/child-android` recursive improvement loop — JVM test expansion, line-by-line review
of services/managers against `docs/SPEC.md` §5 / §14.2, bug fixes with regression tests, and a
green `:app:testDebugUnitTest` + `:app:assembleDebug`.

## Component checklist

| Component | Purpose | Reviewed | Bugs found |
|---|---|---|---|
| `data/RuleEngine.kt` | Pure rule evaluation (routines → app rules → global limit → bedtime → school) | ✅ | 1 (allow/block precedence inside a routine) |
| `data/RuleRepository.kt` | Caches RuleSet (DataStore JSON), FCM topic, `evaluate()`, daily counters | ✅ | 1 (counter logic untestable → extracted; cancellation swallowed) |
| `data/UsageCounters.kt` (new) | Pure per-app daily counters w/ midnight reset | ✅ | — (extracted for testability) |
| `data/AgentSettings.kt` | DataStore identity/settings + sync caches for interceptors | ✅ | 1 (token cache empty after cold start → unsigned requests) |
| `data/WorkScheduler.kt` | Periodic workers (rules 6 h, commands 60 s, telemetry 15 min, midnight) | ✅ | 0 (documented: WorkManager clamps 60 s → 15 min) |
| `data/RulesSyncWorker.kt` / `MidnightResetWorker.kt` | Rules refresh / counter reset jobs | ✅ | 0 |
| `services/LocationService.kt` | FGS location: adaptive interval, 60 s batch flush, Room on failure, ACTION_PING_NOW, 60 s command loop | ✅ | 2 (flush race vs worker/concurrent flush; cancellation swallowed) |
| `services/PendingPingWorker.kt` | Re-uploads Room-persisted pings | ✅ | (shared the flush-race fix) |
| `services/AccessibilityMonitorService.kt` | Foreground events → UsageReporter + evaluate → AppBlocker | ✅ | 0 |
| `services/FirebaseMessagingSvc.kt` | FCM commands + push-token upload | ✅ | 0 |
| `telemetry/UsageReporter.kt` | Usage aggregation + POST telemetry (watermark, unlock counter, battery) | ✅ | 1 (events lost in snapshot/delete race; cancellation swallowed) |
| `telemetry/UsageAggregation.kt` (new) | Pure per-app minutes from event stream | ✅ | — (extracted for testability) |
| `telemetry/TelemetryWorker.kt` | 15-min aggregation job | ✅ | 0 |
| `commands/CommandDispatcher.kt` | lock/unlock/ring/sos_clear/rules_updated/locate_now; ring auto-stop 60 s | ✅ | 1 (locate_now used background-illegal `startService`) |
| `commands/CommandPollWorker.kt` | FCM-free command drain (GET …/commands) | ✅ | 0 |
| `commands/LockActivity.kt` | Lock overlay / keyguard dismiss | ✅ | 0 |
| `enforcement/AppBlocker.kt` | Debounced (2 s/pkg) block overlay; own-package guard | ✅ | 2 (clock-backwards suppression; unbounded debounce map) |
| `enforcement/BlockActivity.kt` | Full-screen block UI; "Request access" → app_blocked alert | ✅ | 0 |
| `setup/PairingActivity.kt` | Pair/claim flow; claim parsing handles `device.id` object AND bare string | ✅ | 1 (scheme-less server URL rejected cryptically) |
| `network/DynamicBaseUrlInterceptor.kt` | Rewrites scheme/host/port/path-prefix to stored base URL | ✅ | 0 (path rewrite extracted for tests) |
| `network/ServerUrls.kt` (new) | Pure URL normalization (scheme prepend, trailing-slash strip) | ✅ | — |
| `network/SignatureInterceptor.kt` | HMAC-SHA256 for `/internal` paths | ✅ | 0 (now test-vector-covered) |
| `network/DeviceAuthInterceptor.kt` | Bearer device JWT | ✅ | 0 (fixed at the settings layer) |
| `receivers/BootReceiver.kt` | Boot: FGS + schedule workers | ✅ | 0 |
| `data/db/*` | Room entities/DAOs | ✅ | 0 |

## Bugs found & fixed

1. **HIGH — `AgentSettings.deviceTokenSync()` returned null on a cold process.**
   The interceptor cache was only populated by a prior suspend read or `savePairing`. After a
   reboot (no UI opened), every request went out **unsigned** → rules refresh, command polling
   and telemetry would 401 until the app was opened. Fix: blocking one-shot DataStore read in
   `deviceTokenSync()` (same pattern as `baseUrlSync()`), with a `tokenLoaded` flag maintained in
   `deviceToken()`/`savePairing()`/`clearPairing()`.
2. **MEDIUM — `CommandDispatcher.locateNow()` silently never worked from the background.**
   `context.startService()` for a service that calls `startForeground()` throws
   `IllegalStateException` on API 26+ when the app is backgrounded (FCM/worker context); the
   `runCatching` hid it. Fix: `ContextCompat.startForegroundService(...)`.
3. **MEDIUM — Location ping flush race (duplicates + lost pings).**
   `LocationService.flushPings()` could run concurrently with itself (flush loop + PING_NOW) and
   with `PendingPingWorker`: two flushes could snapshot the same memory batch → duplicate Room
   rows, and the worker's post-success `clear()` could delete rows the service had just persisted
   unsent. Fix: shared `LocationService.FLUSH_MUTEX` held by both flushes.
4. **MEDIUM — Usage events deleted unsent in `UsageReporter.aggregateAndUpload()`.**
   Cleanup used `deleteOlderThan(windowEnd)`/`watermark = windowEnd`; events inserted between the
   `dao.since()` snapshot and the delete (i.e. during the network POST) were removed without ever
   being aggregated. Fix: anchor delete + watermark to the last aggregated event's timestamp
   (+1 ms); aggregation math extracted to pure `computePerAppMinutes` with regression tests.
5. **LOW — Coroutine cancellation swallowed.**
   `catch (e: Exception)` in `RuleRepository.refresh()`, `LocationService.flushPings()` and
   `UsageReporter.aggregateAndUpload()` also caught `CancellationException`. Fix: rethrow it
   (UsageReporter restores the unlock counter first, so the "counter restored on failure"
   invariant now also holds on cancellation).
6. **LOW — `AppBlocker` debounce edge cases.**
   (a) A backwards system clock made `now - last < 2 s` true for arbitrarily long, suppressing
   the overlay indefinitely; (b) `lastShownMs` grew unboundedly. Fix: debounce only when
   `now - last ∈ [0, 2 s)`, and purge stale entries once the map exceeds 200 packages.
7. **LOW — Scheme-less server URL in PairingActivity.**
   Testers typing `192.168.1.5:3000` hit OkHttp's "Expected URL scheme" error (and the stored
   value would have silently disabled `DynamicBaseUrlInterceptor`). Fix: pure `ServerUrls.normalize`
   prepends `http://` when the scheme is missing and strips trailing slashes; unit-tested.
8. **BEHAVIOR — `allowedApps` now beats `blockedApps` inside one routine.**
   Previously a package present in both lists was BLOCKed (blockedApps checked first). Per QA
   spec edge case, an explicit allow-list membership now exempts the package from that routine
   (NOTE in code + test). Whitelist semantics for non-members are unchanged (still BLOCK).
9. **NOTE — `CommandPollWorker` "every 60 s" is OS-clamped.**
   WorkManager raises any periodic interval < 15 min to 15 min; the true 60 s cadence (§14.2) is
   delivered by LocationService's in-process command loop while the FGS runs. Documented in code.

## Tests added (all pure JVM, no Android framework)

- `RuleEngineEdgeCasesTest` (16 tests): routine wrap-midnight (both sides + day-gated tail),
  allowedApps-beats-blockedApps, whitelist member/non-member, school-hours weekday gating incl.
  weekends for days=[1..5] and start/end inclusivity, routine-vs-allow-vs-bedtime priority order
  (3 tests), time_limit exactly-at-limit / zero-is-unlimited / null-weekend-fallback, unknown
  package default (+ school-hours device-wide coverage), weekend vs weekday global limits,
  zero-weekend fallback, cross-app global sum, bedtime boundary inclusivity, malformed "HH:mm".
- `UsageCountersTest` (7 tests): gap crediting, 5-min cap, in-progress snapshot without double
  counting, backwards-clock/sub-minute gaps, midnight reset (auto + explicit), same-day no-op.
- `UsageAggregationTest` (5 tests): per-app minutes, 5-min gap cap, window tail, empty stream,
  negative/out-of-order gaps.
- `SignatureInterceptorTest` (3 tests): known HMAC-SHA256 vector, hex shape, secret sensitivity.
- `ServerUrlsTest` (6 tests): scheme prepend/preserve, trailing slashes, trim, blank, path prefix.
- `DynamicBaseUrlInterceptorTest` (5 tests): root path, /api prefix, no-trailing-slash, https +
  custom port, default ports.
- Pre-existing `RuleRepositoryTest` (6 tests) untouched and still green.

Total: 48 JVM tests.

## Residual risks

- **Backfill double counting (known, not fixed):** `UsageReporter.backfillFromUsageStats` adds
  full-day UsageStats totals for packages missing from the accessibility event stream on *every*
  15-min cycle; if the backend treats telemetry as deltas, those packages are over-counted.
  Proper fix needs per-package daily watermarks — out of scope for a minimal QA pass.
- **Wrap-midnight routine tails are day-gated:** a 22:00–06:00 routine on `days=[Mon]` does not
  apply on Tuesday 05:00 (documented in code/tests as the simplest interpretation).
- **Counters are in-memory** (per SPEC §5): usage minutes reset on process death; acceptable.
- **Room `pending_pings` grows while offline** (bounded only by storage); drained by
  PendingPingWorker when the network returns.
- **60 s command cadence depends on LocationService running** (see bug 9); a killed service
  degrades command latency to the WorkManager 15-min floor.
- **Ring race window:** two `ring` commands within milliseconds can orphan a started MediaPlayer
  before it is registered; auto-stop jobs still bound it to ≤ 60 s of audio. Extremely unlikely
  via server-driven commands.
- **Android 14 background FGS restrictions:** starting the location FGS from FCM/worker context
  may be blocked by the OS on some OEM builds (guarded by runCatching; ping then waits for the
  next flush cycle).
- Unlock counter is process-local (lost on process death); watermark/anchor logic only guards
  Room-persisted events.
