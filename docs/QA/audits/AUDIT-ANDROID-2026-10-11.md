I've completed a thorough read of the Android agent's enforcement, state, networking, telemetry, comms, social-capture, and pairing code, plus the relevant server-side contracts. Here is the findings report.

## Android child-agent audit

### AND-01 — critical — tamper / install / VPN alerts are rejected by the server and silently dropped
- **File**: `services/api/src/routes/alerts.ts:22` (schema enum) vs agent senders `apps/child-android/app/src/main/java/com/familyshield/agent/receivers/AccessibilityOffReceiver.kt:38`, `.../services/LocationService.kt:266`, `.../receivers/PackageAddedReceiver.kt:66`, `.../comms/CommsLogger.kt:230`
- **What breaks**: `InternalAlertSchema.category` is `z.enum([... "sos", "ai_concern", ...])` with only 9 values. The agent posts `category = "tamper"`, `"vpn_detected"`, `"install_request"`, and `"unknown_contact"` — none are in the enum, so the server returns `400 invalid payload` and the parent never learns about accessibility-disabled tamper, VPN routing, new-app installs, or unknown contacts.
- **Repro / trigger**: Pair a device, install any app (install_request) or turn off the OSRA accessibility service (tamper) or connect a VPN; watch the server logs for a 400 on `/v1/alerts/internal`.
- **Expected vs actual**: Expected the parent to receive a tamper/install/VPN/unknown-contact alert; actual is a server-side 400 with the alert never persisted.
- **Suggested fix direction**: Extend the alert category enum (the shared types already define `tamper`, `vpn_detected`, `install_request`, `unknown_contact` in `packages/shared-types/src/world-class.ts`) or map the agent to accepted categories, then add a round-trip test for each category the agent actually sends.

### AND-02 — critical — screen-time counters are in-memory only, so a reboot resets the daily/per-app limits
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/data/RuleRepository.kt:41` and `.../data/UsageCounters.kt:5`
- **What breaks**: Enforcement (`RuleRepository.evaluate`) reads `minutesUsedToday` from the in-memory `UsageCounters`, which is never persisted and never reconstructed from the Room `usage_events` table. Rebooting (or force-stop + restart of the process) resets used minutes to 0.
- **Repro / trigger**: Child reaches the daily limit, powers the phone off/on, and immediately reopens the blocked app.
- **Expected vs actual**: Expected the limit to survive a reboot; actual is full allowance restored.
- **Suggested fix direction**: Persist today's per-app minutes (or the raw event stream) and rebuild `UsageCounters` on process start, anchored to the local date.

### AND-03 — high — no rules loaded → every app is allowed (fail-open)
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/data/RuleRepository.kt:65`
- **What breaks**: `val ruleSet = cached ?: return Decision.ALLOW` means that before the first successful rules fetch (or after the DataStore rules JSON is gone), the accessibility monitor blocks nothing at all.
- **Repro / trigger**: Pair, then immediately kill network before `syncNow` completes, or clear the app's storage; open a blocklisted app.
- **Expected vs actual**: Expected enforcement from persisted rules; actual is a temporary unenforced window that can last until the next successful sync.
- **Suggested fix direction**: Fail closed when paired but no cached rules exist (return `BLOCK` for non-exempt packages), or block setup completion until the first rule set is persisted.

### AND-04 — high — block overlay is dismissible, giving a ~2 s reuse window per dismissal
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt:143` and `.../enforcement/AppBlocker.kt:39`
- **What breaks**: `BlockActivity` shows a "Close" button that calls `finish()`, and there is no `onBackPressed`/`onUserLeaveHint` guard or keep-screen-on flag. `AppBlocker` debounces re-showing for 2 s, so a child can dismiss the overlay and use the blocked/time-limited app in repeated ~2 s bursts.
- **Repro / trigger**: Open a blocked app, tap "Close" (or Back), interact for ~2 s, repeat.
- **Expected vs actual**: Expected the block to be inescapable; actual is burstable access.
- **Suggested fix direction**: Remove the free-dismiss path (or gate it behind a parent PIN), intercept back presses, and re-block immediately rather than after a 2 s debounce.

### AND-05 — high — parent `lock`/`pause` fallback overlay (non-device-owner) has no exit prevention
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/commands/LockActivity.kt:49` and `.../commands/CommandDispatcher.kt:86`
- **What breaks**: When the app is not device owner, `lock`/`pause`/`wind_down` fall back to a full-screen `LockActivity` overlay with no back/home/recents guard. A child can press Back or Home to dismiss the "device locked by your parent" screen and continue using the device.
- **Repro / trigger**: Parent sends `lock` on a non-device-owner device; child presses Back.
- **Expected vs actual**: Expected the device to stay locked until `unlock`; actual is the lock is trivially dismissed.
- **Suggested fix direction**: Provision device owner in production, and for the fallback overlay use a pinned-screen/launcher interception strategy or at minimum intercept back and re-raise the overlay on resume.

### AND-06 — medium — pause-internet flag is in-memory and lost on reboot
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/data/RuleRepository.kt:47` and `.../commands/CommandDispatcher.kt:125`
- **What breaks**: `pausedInternet` is a `@Volatile` process-local boolean. Since the test build enforces pause via this flag (no VPN sinkhole yet), rebooting clears it and the child regains internet while the parent still believes it is paused.
- **Repro / trigger**: Parent sends `pause_internet`; child reboots the phone.
- **Expected vs actual**: Expected pause to persist across reboot; actual is internet unblocked until the next command or sync.
- **Suggested fix direction**: Persist the pause flag in DataStore and restore it on process start (and re-assert the overlay).

### AND-07 — medium — bonus minutes are lost on reboot and never restored, contradicting the self-heal comment
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/data/RuleRepository.kt:50` and `.../network/dto/RulesDtos.kt:7`
- **What breaks**: `bonusMinutesToday` lives only in memory. The comment claims the server persists it and a rules refresh self-heals, but the agent's `RuleSetDto` has no `bonusMinutesToday` field, so `refresh()` never repopulates it.
- **Repro / trigger**: Parent grants `bonus_time 30`; child reboots before using it.
- **Expected vs actual**: Expected bonus to survive via next rules refresh; actual is the bonus is gone permanently.
- **Suggested fix direction**: Add `bonusMinutesToday` to `RuleSetDto` and seed `bonusMinutesToday` from it in `refresh()`.

### AND-08 — medium — global screen-time limit counts always-allowed apps and the launcher
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/data/RuleEngine.kt:92` and `.../services/AccessibilityMonitorService.kt:20`
- **What breaks**: `minutesUsedToday.values.sum()` includes every foreground package except the agent's own — including always-allowed (educational) apps and the home screen/launcher. Idle time on the launcher or time in an always-allowed app consumes the daily budget and can trigger a `TIME_LIMIT_REACHED` block for everything else.
- **Repro / trigger**: Child spends most of the day on the launcher or an always-allowed app, then opens a normal app and is blocked despite little actual app usage.
- **Expected vs actual**: Expected the limit to track the apps it governs (and exempt always-allowed); actual is over-counting that inflates usage.
- **Suggested fix direction**: Exclude `alwaysAllowedApps` (and optionally the launcher/system UI) from the global total, or track a separate "counted usage" stream.

### AND-09 — medium — social capture walks the node tree on the accessibility main thread and leaks nodes on early return
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialCapture.kt:50`
- **What breaks**: `collectVisibleText` is a synchronous recursive walk that runs directly in `onAccessibilityEvent` (main thread). When a node is invisible or the 4000-char budget is reached, the function returns without recycling the already-fetched child `AccessibilityNodeInfo`, and deep trees can cause jank/ANR.
- **Repro / trigger**: Open WhatsApp/Instagram with a long chat and rapidly scroll — observe main-thread stalls and gradual native memory growth.
- **Expected vs actual**: Expected bounded, off-main-thread capture; actual is main-thread recursion plus node leaks.
- **Suggested fix direction**: Run the capture on a background scope, recycle children in `finally`, and/or switch to `AccessibilityService.getWindows()` + explicit recycling.

### AND-10 — medium — unbounded buffering/DB growth when uploads keep failing
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:148` and `.../telemetry/UsageReporter.kt:84`
- **What breaks**: `memoryPings` grows without bound in memory while offline, and `pending_pings`, `comms_events`, and `usage_events` rows are only deleted on successful upload. A child who stays offline for days accumulates unbounded rows (usage events are also appended on every accessibility event).
- **Repro / trigger**: Airplane mode for several days while using the phone normally; check DB size and memory.
- **Expected vs actual**: Expected capped retention; actual is unbounded growth and potential disk/memory exhaustion.
- **Suggested fix direction**: Cap the in-memory ping list, add size/age-based eviction to the Room tables, and delete already-aggregated usage events regardless of upload success (or use a bounded retry queue).

### AND-11 — medium — telemetry watermark race can delete a just-inserted usage event unsent
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt:80`
- **What breaks**: In the empty-events branch, `newWatermark = windowEnd + 1` where `windowEnd` was captured before the DAO query. An event recorded after that snapshot but with a timestamp `<= windowEnd` can be deleted by `deleteOlderThan(newWatermark)` before it is aggregated.
- **Repro / trigger**: Run the 15-min telemetry worker while the accessibility stream is actively recording; occasionally an event is silently dropped from both telemetry and live-activity totals.
- **Expected vs actual**: Expected no event loss; actual is a narrow window of lost usage.
- **Suggested fix direction**: Use a monotonic DB id instead of wall-clock timestamps for the watermark, or clamp the empty-branch watermark to `oldestTimestamp()` rather than `windowEnd`.

### AND-12 — low — device identifier is logged to logcat on every request
- **File**: `apps/child-android/app/src/main/java/com/familyshield/agent/di/NetworkModule.kt:44`
- **What breaks**: `HttpLoggingInterceptor` at `Level.BASIC` logs every request URL, which includes the device id in `/v1/devices/<id>/…` paths (and child id in `/v1/rules/<childId>`), exposing identifiers to any process that can read logcat.
- **Repro / trigger**: Run any telemetry/command/location upload and inspect `adb logcat`.
- **Expected vs actual**: Expected identifiers not in logs; actual is device/child ids present in BASIC URL logging.
- **Suggested fix direction**: Disable logging in release, or use `Level.NONE`/redact path segments.

### Verified solid (do not touch)
- HMAC signing matches the server: `SignatureInterceptor` signs only `internal` paths and the server verifies per-device secrets from the body's `deviceId` (`SignatureInterceptor.kt:20`, `internalAuth.ts:23`).
- Cold-start interceptor reads are correct — `deviceTokenSync()`/`hmacSecretSync()` block once per process so fresh processes don't send unsigned requests (`AgentSettings.kt:79-107`).
- Pairing claim correctly reads `hmacSecret` from the claim response (server mints it per device) and the form enforces a blank/required server field with no default (`PairingActivity.kt:232`, `PairingActivity.kt:96-108`).
- Minutes parsing/clamping is correct and shared between bonus_time and wind_down (`CommandDispatcher.kt:251`).
- Rule-window math is correct: ISO day-of-week (1=Mon..7=Sun), midnight-wrapping windows, and weekend/weekday limit selection (`RuleEngine.kt:111-125`).
- Location flush and pending-ping worker serialize on a shared mutex, preventing duplicate uploads / premature deletes (`LocationService.kt:290`, `PendingPingWorker.kt:31`).