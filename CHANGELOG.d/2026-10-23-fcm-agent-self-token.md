### Child agent — roadmap 1.5: a push wakes the agent, it never carries the command (#319)

Claude's Decision 2 (issue #319, 2026-10-23), the Android half of roadmap 1.5. The token contract is
back on the decided route, and `FirebaseMessagingSvc` no longer dispatches push data.

- **The must-fix — a push is a wake-up only.** `apps/child-android/app/src/main/java/com/familyshield/agent/services/FirebaseMessagingSvc.kt:40`
  no longer reads `msg.data["type"]` or hands the message to `CommandDispatcher`; that dependency is
  gone from the service entirely, so a data-dispatch path fails to compile rather than only a test.
  Every message now goes through `PushWakeHandler` (`push/PushWakeHandler.kt`), which **polls
  in-process once** via the newly extracted `CommandPoller.pollOnce`
  (`commands/CommandPoller.kt`) — the same fetch-and-dispatch body the periodic worker used to hold —
  and **falls back** to a one-shot `CommandPollWorker` only when that poll throws or cannot run.
- **The wake runs inside FCM's callback window (#322 review).** `onMessageReceived` used to hand the
  poll to a detached `scope.launch`, which returns immediately: the poll then runs *after*
  `onMessageReceived` has returned, and FCM's background limits can pause or terminate the process
  **without an exception**. Nothing throws, so the fallback never fires, and the command waits for the
  periodic poll — clamped to ~15 minutes, which is precisely the case the acceptance row is about. It
  now uses `runBlocking` (FCM's own worker thread, never the main thread) with an **8 s budget** in
  `PushWakeHandler` (`WAKE_BUDGET_MS`, well inside FCM's ~20 s window); a poll that overruns is handed
  to the one-shot worker as well. `withTimeoutOrNull` converts its own timeout to `null`, so a slow
  poll is handled like a failed one, while a real outer cancellation still reaches the rethrow.
  **Why the in-process attempt is primary:** lowest latency, which is what a `lock` needs; **why the
  worker is the fallback:** a `FirebaseMessagingService` has no `goAsync()`, so the process can be
  reclaimed the moment the callback returns, and WorkManager work outlives it. **Why content is never
  read:** Google must never see command content — `show_reset_code` carries the parent's reset code
  and a location request carries the timing of a family's day — and a stale or misdirected token then
  leaks nothing. Push and poll run through one code path and the same idempotent acks.
- **The extraction is a move, not a redesign.** `CommandPoller` (`@Singleton`, Hilt-injected) now holds
  `pollOnce`: not-paired is a normal return, the stored-token retry runs first, each command is
  dispatched with its row id, and a per-command failure is still swallowed and logged. The worker keeps
  its `Result` mapping (retry while `runAttemptCount < 3`, then failure), the failure log line, the
  network constraint, the expedited one-shot helper and `getForegroundInfo`. The only visible difference
  is the per-command swallow log's tag (`CommandPoller` instead of `CommandPollWorker`); message and
  level are unchanged. No existing test assertion needed changing.
- **The fallback trigger.** `CommandPollWorker.requestFetchNow` enqueues the worker as one-shot
  **expedited** work (`RUN_AS_NON_EXPEDITED_WORK_REQUEST` fallback) under its own unique name
  `command_poll_wake`, with `ExistingWorkPolicy.KEEP` and the poll's network constraint. `KEEP`
  collapses a burst of pushes into the one pending fetch (which drains the whole queue) and cannot
  cancel the periodic poll, whose `command_poll` name would collide in WorkManager's shared unique-work
  namespace. `getForegroundInfo` was added because expedited work runs as a foreground service below
  Android 12 and WorkManager refuses a worker that cannot describe its notification; minSdk is 26.
- **The token contract, reverted to the decision.** `POST /v1/devices/{id}/push-token`
  (`network/ApiService.kt:57`) — the existing route, device-only, body `{ "token": string }` (20–4096),
  response `204`; server half is PR #320. The branch's `/push-token/self` path and `pushToken` body field
  are gone (`network/dto/PayloadDtos.kt:42`), and `PushTokenRouteTest` pins both halves so a revert to
  either fails.
- **Tests (JVM).** `PushWakeHandlerTest` (4: exactly one in-process poll and no worker on success; a
  throwing poll gives exactly one fallback and no second poll; `type=lock`, `{"w":"1"}` and an empty
  map all behave identically — content is never read; cancellation is rethrown and does not enqueue the
  fallback). `FirebaseMessagingSvcWiringTest` (4: reflection — no `CommandDispatcher` field and none as
  a constructor parameter, with a message naming the defect; source — `onMessageReceived` indexes
  `msg.data` nowhere, references no dispatcher, and wakes through `PushWakeHandler` +
  `CommandPoller.pollOnce` + the worker fallback; source — the handler's own body never indexes `data`).
  `PushTokenRouteTest` keeps its 3 and asserts the decided path and `{"token":…}`.
- **Gates (this branch, author-run).** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest` →
  **620 tests per flavour, 0 failures, 0 errors, 0 skipped** (87 suites each), `BUILD SUCCESSFUL`.
  `./gradlew :app:assembleDebug` → `BUILD SUCCESSFUL` with **no `app/google-services.json`**: the
  conditional gms plugin (kept from this branch) leaves the FCM-free build the default.
- **Mutants measured**, each applied → failing suite → reverted → green again: route repointed at
  `.../push-token/self` (`PushTokenRouteTest`, ComparisonFailure `/self`); DTO renamed `pushToken`
  (`{"pushToken":"fcm-319"}` vs `{"token"…}`); a second in-process poll (`expected:<1> but was:<2>`);
  the fallback fired twice from the failure branch (fallback count 2); the poll retried inside that
  branch (`must not be retried in-process expected:<1> but was:<2>`); `if (data["type"] == null)
  return` in `PushWakeHandler` (the no-type cases poll 0 while `type=lock` stays green, and the
  handler-source check fails); `CommandDispatcher` restored as a field (`declares [dispatcher] …`) and
  as a constructor parameter (`has a constructor parameter of type CommandDispatcher`); `msg.data["type"]`
  read restored in the service (`onMessageReceived reads message content`).

**Not verified in this change:** no real Firebase project and no `google-services.json` exist here, so
delivery of an actual push and `onNewToken` were not exercised; the server half is PR #320 and no live
server was contacted; no hardware row was run, so "a lock lands in under 5 s with the app backgrounded"
and the pre-Android-12 expedited foreground path are unobserved. The unit-test seam needs no Firebase:
`PushWakeHandler` is pure JVM and the wiring test only loads the service class.
