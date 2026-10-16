# OSRA Android child agent — enforcement audit (read-only), 2026-10-16

Paths below are relative to `apps/child-android/app/src/main/java/com/familyshield/agent/` unless noted. Manifest = `apps/child-android/app/src/main/AndroidManifest.xml`. Base: `main@fe1997c`.

## Per-feature findings

**1. Remote LOCK — Partial (overlay only).** `CommandDispatcher.kt:86-96` calls `lockNow()` only if `isDeviceOwnerApp`, else starts `LockActivity`. The device-owner branch is dead code: there is **no `DeviceAdminReceiver`, no `device_admin.xml`, no `BIND_DEVICE_ADMIN`** anywhere in the manifest, so the app can never be provisioned as owner/admin. No lock-task mode (`startLockTask` absent). The overlay swallows Back (`LockActivity.kt:45-49`) and re-raises itself in `onUserLeaveHint`/`onPause` (`:58-78`). Bypasses: swipe-away from Recents kills the task; notification shade remains usable; lock state is in-memory only, so a **reboot clears it** entirely (BootReceiver only restarts LocationService, `receivers/BootReceiver.kt:12-17`); safe mode disables the app. `SYSTEM_ALERT_WINDOW` is declared (manifest:11) but **never requested** (no `canDrawOverlays`/`ACTION_MANAGE_OVERLAY_PERMISSION` in code), so `startActivity` from the FCM/poll/FGS context is subject to Android 10+ background-activity-start restrictions and may silently not appear — needs on-device verification.

**2. FIND / locate — Implemented.** `services/LocationService.kt`: FusedLocationProvider, `PRIORITY_BALANCED_POWER_ACCURACY`, adaptive 30 s moving / 5 min stationary (`:323-328`), 60 s batch flush, Room fallback + `PendingPingWorker` (30 min, network-constrained). `locate_now` exists (`CommandDispatcher.kt:218-229`) but only returns `fused.lastLocation` (cached fix, `LocationService.kt:128`), not a fresh high-accuracy request. `ACCESS_BACKGROUND_LOCATION` declared (manifest:4) but **never requested at runtime** (`PairingActivity.kt:338-352` asks FINE/COARSE/POST_NOTIFICATIONS only); tracking survives only because it is a location FGS. No battery-optimization exemption request. If location permission is denied the FGS refuses to start (`:211-215`) and with it the 60 s command poll and tamper checks die.

**3. RING — Partial.** `CommandDispatcher.kt:180-203`: `MediaPlayer` on `USAGE_ALARM`, looping default alarm, auto-stop 60 s. Does **not** set the alarm stream to max (no `AudioManager.setStreamVolume`), no wake lock, no screen-on, no stop UI. Alarm usage bypasses silent mode and default DND, but a child who sets alarm volume to 0 gets silence.

**4. App blocking & screen time — Implemented (accessibility-only).** `AccessibilityMonitorService.kt:26-38` evaluates every `typeWindowStateChanged|typeWindowContentChanged` event and launches `BlockActivity` (debounced 2 s, `enforcement/AppBlocker.kt:33-54`). `RuleEngine.kt` is a clean pure evaluator (routines, per-app, blocklist, global/weekend limit + bonus, bedtime, school). Counters persist across reboot (`RuleRepository.kt:139-160`). Fail-closed when paired with no rules (`:70-77`). `UsageStatsManager` is used only as telemetry backfill (`telemetry/UsageReporter.kt:128-142`), never for enforcement, and `PACKAGE_USAGE_STATS` is never requested via Settings. If accessibility is off there is **zero enforcement** — only a tamper alert (see #8). Bypasses: PiP/split-screen (no new window event), disabling accessibility, and clearing app data.

**5. Social monitoring — Partial, chats-only.** `social/SocialCapture.kt:27-47` walks the visible node tree (text + contentDescription, ≤4000 chars) for 14 packages (`MonitoredApps.kt:10-23`: WhatsApp/Business, Instagram, TikTok, Snapchat, X, Discord, Roblox, LINE, YouTube/Kids, Telegram, Reddit, Messenger). Heuristic: message = **longest visible node**, contact = first short node (`SocialHeuristics.kt:30-38`). Only that single redacted string + contact is sent to `/v1/social/scan` (`SocialScanQueue.kt:78-86`); phones/emails/4+digit runs redacted first (`TextRedaction.kt`). **No `NotificationListenerService`** in the manifest, no screenshots, so messages received while the app is backgrounded are missed; no calls, voice notes, media, or **WhatsApp call detection** (string "call" never appears in `social/`). Failed sends are dropped (`:88`).

**6. Calls & SMS — Implemented (log-only).** `READ_CALL_LOG`/`READ_SMS` declared (manifest:15-16), requested as optional (`PairingActivity.kt:178-183`). `comms/CommsLogger.kt:60-65` registers ContentObservers; calls = number/duration/direction; SMS = number + **first 120 chars of body** (`:156`, `:263`), sent unredacted to `/activity`. No MMS/RCS, no blocking. Observers start in `Application.onCreate` so they die with the process.

**7. Pause internet / web filtering — Stub.** No `VpnService`, no `BIND_VPN_SERVICE`, no DNS filtering, no URL capture, no SafeSearch. `pause_internet` is just the overlay + an **in-memory flag** (`RuleRepository.kt:51`, lost on process death) and `WebFilterRuleDto` is carried but never read (`network/dto/RulesDtos.kt:45-51`). Comments in `CommandDispatcher.kt:121-123` and `RuleEngine.kt:44-45` describe a "production VpnService sinkhole" that does not exist in this repo.

**8. Tamper resistance — Stub.** No device admin → **the child can uninstall normally**, clear data, or force-stop. Worse: the launcher activity's **"Re-pair" button clears pairing with no parent PIN** (`PairingActivity.kt:273-283` → `settings.clearPairing()`), after which `evaluate` returns ALLOW for everything (`RuleRepository.kt:76`). Accessibility-off detection is a 60 s poll inside LocationService (`receivers/AccessibilityOffReceiver.kt:25-47`), alert-only, throttled 1/hour. VPN detection is the same (`LocationService.kt:280-302`). `MY_PACKAGE_REPLACED` alert exists. No battery-optimization exemption, no OEM autostart guidance, no Play Protect handling. Secrets (JWT, HMAC) in plain Preferences DataStore despite `security-crypto` being a dependency.

**9. Push — Stub (polling in practice).** `FirebaseMessagingSvc.kt` is wired in the manifest and `firebase-messaging-ktx` is a dependency, but there is **no `google-services.json` and no `com.google.gms.google-services` plugin** (`app/build.gradle.kts:1-7`), so FirebaseApp is never initialised; `subscribeToTopic` is swallowed by `runCatching` (`RuleRepository.kt:189`). Real delivery is the 60 s in-process poll while the location FGS runs (`LocationService.kt:113-124`) and a WorkManager poll clamped to ~15 min (`data/WorkScheduler.kt:33-42`).

**10. SOS — Implemented (minimal).** Quick tile → `SosActivity` (`sos/SosTileService.kt`), 5 s cancellable countdown via pure `SosStateMachine`, then one HMAC `critical/sos` alert (`SosActivity.kt:91-108`). No location attached, no audio/photo, no call/SMS to parent, no persistence/retry if offline.

**11. Pairing & onboarding — Partial.** Server URL + 6-digit code (`PairingActivity.kt:102-161`). Afterwards: optional call/SMS prompt, location prompt, and a button that opens Accessibility Settings (`:178-206`). **No guided/verified steps** for accessibility (not checked on return), usage access, overlay, battery optimisation, or device admin; no completion gate.

**12. Build health.** minSdk 26 / target+compile 34 (`build.gradle.kts:11-17`) — below the Play target-35 requirement, so not submittable as-is. Release is **debug-signed** (`:29-32`), cleartext HTTP allowed globally (`res/xml/network_security_config.xml`), HTTP logging in all builds, no minify/ProGuard, versionCode 1. Both kapt and ksp. Likely compiles (AGP 8.4.1, Kotlin 1.9.24, Gradle 8.7, Compose 1.5.14 are consistent). Tests: 22 files / 155 `@Test`, **all pure JVM** (no `android.*` imports, no `androidTest/`). They cover RuleEngine, counters, heuristics, redaction, policies, URL parsing — **nothing exercises LockActivity, AppBlocker, the accessibility service, LocationService, CommsLogger, or pairing.**

## Feature table

| Feature | Status | Mechanism | Main bypass |
|---|---|---|---|
| Remote lock | Partial | Overlay activity | Recents swipe, reboot, no device admin |
| Locate | Implemented | Fused FGS, adaptive | Deny location → agent mostly dead |
| Ring | Partial | MediaPlayer/ALARM 60 s | Alarm volume 0 |
| App block / limits | Implemented | Accessibility events | Turn off accessibility, PiP |
| Social monitoring | Partial | Visible-node scrape, chats only | Background msgs, calls/media invisible |
| Calls/SMS log | Implemented | ContentObservers | Optional permission |
| Pause internet / web filter | Stub | Overlay + RAM flag | Process death, any browser |
| Tamper resistance | Stub | Alerts only | Uninstall, Re-pair button |
| Push | Stub | 60 s / 15 min polling | — |
| SOS | Implemented | Tile + alert | No location, no retry |
| Onboarding | Partial | Buttons, unverified | Steps skippable |
| Build | Not shippable | debug-signed, target 34 | — |

## Top 5 gaps vs Qustodio / Family Link

1. **No device-admin / device-owner layer**: uninstall, force-stop, clear-data and the unauthenticated Re-pair button all remove protection in seconds.
2. **No web filtering or network control** (no VpnService/DNS/SafeSearch/URL capture); "pause internet" is a cosmetic overlay.
3. **Lock is dismissable and non-persistent** (no lock-task, not surviving reboot, overlay permission never granted).
4. **Push is not real** — commands land in 60 s at best and only while the location FGS survives, ~15 min otherwise.
5. **Social monitoring is a foreground scrape**: no notification listener, no calls/media, heuristic message extraction, best-effort delivery.

## Readiness: 3/10

The pure logic (rule engine, counters, redaction, throttles) is tidy, well-commented and well tested, and the location/telemetry pipeline is genuinely functional. But everything that makes a parental-control agent credible against a motivated child — uninstall protection, a lock that holds, network filtering, real push, verified onboarding — is either absent or exists only as comments describing a "production path" that is not in the repo. Combined with the debug-signed, cleartext, target-34 build, this is a solid prototype/test harness, not a product a Qustodio or Family Link user would take seriously yet.
