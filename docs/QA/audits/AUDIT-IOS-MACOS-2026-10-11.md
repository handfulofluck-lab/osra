## Apple clients audit (iOS + macOS)

Scope read in full: all 9 Swift files + `Package.swift` under `apps/child-ios`, `QA-IOS.md`, `docs/test-guides/IOS-BUILD-NOTES.md`, the macOS scaffold (3 C# files + csproj + README), and the server contract it talks to (`services/api/src/routes/devices.ts`, `routes/alerts.ts`, `lib/internalAuth.ts`). No compilation is possible here, so every finding is tagged **[certain-from-code]** (provable by reading) vs **[needs-Mac]** (Apple API/runtime behavior to confirm on a real SDK/device).

---

### IOS-01 — Every iOS alert is rejected with 401 (signature verified against the wrong secret)
- **Severity**: critical
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/DeviceActivityMonitor.swift:43-59` (payload + signing); server: `services/api/src/lib/internalAuth.ts:20-30`, `services/api/src/routes/devices.ts:138,158`
- **What breaks**: The whole alert pipeline. `AlertReporter.report` builds the JSON body as `{childId, category, severity, title, body, metadata}` — **no top-level `deviceId`**. `verifyInternalSignature` only looks up a device's per-device secret *when the body contains `deviceId`*; otherwise it falls back to the global `INTERNAL_HMAC_SECRET`. The iOS client signs with `agent.hmacSecret`, which is the **per-device** random secret minted at claim time (`randomBytes(32).toString("hex")` → returned as `hmacSecret`). Per-device secret ≠ global secret ⇒ signature mismatch ⇒ `401 invalid_signature` on every alert.
- **Trigger**: Any `eventDidReachThreshold` or shield-action report that reaches the server.
- **Expected vs actual**: QA-IOS.md claims the reporter "signs the body … and logs non-2xx responses" and the build notes expect "202, not 401". Actual: guaranteed 401 because the client signs with the device secret but the server compares against the global secret (the `deviceId` key that would route verification to the device secret is absent).
- **Fix**: Add `"deviceId": <agent.deviceId>` to the payload (the value is already persisted at `agent.deviceId`, `AgentIdentityStore.swift:23`; just add a `pairedDeviceId()` reader and include it). Then the server picks `device.internalSecret`, which matches `agent.hmacSecret`.
- **Confidence**: certain-from-code (both sides read verbatim).

### IOS-02 — App shielding can never work: tokens are synthesized from bundle IDs, and the only supported token source is absent
- **Severity**: critical
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/ScreenTimeController.swift:88-90`, `:29-30`; `DeviceActivityMonitor.swift:116-118,127-128`
- **What breaks**: `TokenResolver.applicationTokens(forBundleIdentifiers:)` does `Application(bundleIdentifier: $0).token`. But `ApplicationToken` is an opaque privacy token (`typealias ApplicationToken = Token<Application>`); Apple documents that *"FamilyActivitySelection provides tokens"* and that tokens are *"voided"* when authorization is revoked, and `ManagedSettingsStore` even has `static func refresh(inout [ApplicationToken]) throws` for *"expired ApplicationTokens"*. Tokens usable for `store.shield.applications` come from a `FamilyActivityPicker` → `FamilyActivitySelection` round-trip (encode/decode, since `FamilyActivitySelection` is `Codable`). The codebase contains **no picker, no selection, no persistence** (grep confirms `FamilyActivitySelection`/`FamilyActivityPicker` appear only in a comment). Bundle-ID-based blocking belongs on `store.application.blockedApplications = Set<Application>` (`ApplicationSettings`), not on `shield.applications`.
- **Trigger**: `applyBlockedApps(packageIds:)` or a bedtime/rule interval applying a shield.
- **Expected vs actual**: Expected — blocked apps get the "Blocked by OSRA" shield. Actual — the synthesized token is not a selection-issued token, so the shield either fails to resolve to an app or silently does nothing (no exception, no log).
- **Fix**: Introduce a `FamilyActivityPicker` in the pairing/setup flow, persist the encoded `FamilyActivitySelection` (app group or Keychain), decode it in the app/extensions, and resolve rule bundle-IDs against `selection.applicationTokens`; use `store.application.blockedApplications` if raw bundle-ID blocking is the actual goal. The code's own NOTE (lines 80-84) acknowledges this but the code still ships the broken synthesis path as the *only* path.
- **Confidence**: certain-from-code that the sanctioned path is absent and that tokens are being synthesized from bundle IDs; **[needs-Mac]** to observe the exact failure mode (nil token vs non-functional shield).

### IOS-03 — `store.shield.applicationCategories` / `webDomainCategories` type mismatch (won't compile)
- **Severity**: high
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/ScreenTimeController.swift:42-44`
- **What breaks**: These lines assign a `Set<ActivityCategoryToken>` to properties whose current type is `ShieldSettings.ActivityCategoryPolicy<Application>?` / `ActivityCategoryPolicy<WebDomain>?` (an enum with `.none` / `.all(except:)` / `.specific(_:except:)`), per Apple's `ShieldSettings` API. `categoryTokens` returns `Set<ActivityCategoryToken>`, so `categories.isEmpty ? nil : categories` is a type error.
- **Trigger**: First build against a current iOS SDK (the `#if canImport(ManagedSettings)…` gate is true on iOS).
- **Expected vs actual**: Expected — category shields applied. Actual — compile error (or, on a hypothetical older SDK, a dead call since `categoryTokens` always returns `[]`).
- **Fix**: Use `.specific(categories, except: [])` / `.none`, and actually populate `categoryTokens` from a persisted `FamilyActivitySelection`.
- **Confidence**: certain-from-Apple-docs (current `ShieldSettings` signature); **[needs-Mac]** to confirm against the exact SDK they'll build with.

### IOS-04 — `ShieldConfiguration.Label(text:color:)` passes `nil` to a non-optional `color` (won't compile)
- **Severity**: high
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/ShieldConfiguration.swift:32,33,34,36`
- **What breaks**: `ShieldConfiguration.Label`'s only initializer is `init(text: String, color: UIColor)` (no default, `color` non-optional). Four call sites pass `color: nil`.
- **Trigger**: First build of `ShieldConfiguration.swift` (compiled inside the `#if canImport(UIKit) && canImport(ManagedSettings) && canImport(ManagedSettingsUI)` gate, which is true on iOS).
- **Expected vs actual**: Expected — shield UI renders. Actual — "cannot convert value of type 'nil' to expected argument type 'UIColor'".
- **Fix**: Pass concrete `UIColor`s (e.g. `.label`/`.systemBlue`) or add a local convenience initializer that defaults the color.
- **Confidence**: certain-from-Apple-docs (verified `ShieldConfiguration/Label` page); **[needs-Mac]** for the final SDK confirmation.

### IOS-05 — Bedtime-end un-shields rule-blocked apps and overlapping routines clobber each other
- **Severity**: high
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/DeviceActivityMonitor.swift:114-129` (start/end), `:145-156` (key readers)
- **What breaks**: `intervalDidStart`/`intervalDidEnd` share a single default `ManagedSettingsStore()`. `intervalDidEnd` re-applies `apps.blockedBundleIdentifiers` to "restore" the rule shield — but **no committed code ever writes that key** (or `bedtime.blockedBundleIdentifiers`; grep confirms both are read-only at `DeviceActivityMonitor.swift:149,155`). So at bedtime end the store is set to `nil`, wiping everything. Separately, with two overlapping bedtime routines on the same store, routine A's `intervalDidEnd` overwrites routine B's still-active bedtime shield (and the bedtime list is one global key, not per-routine, so routines can't even differ).
- **Trigger**: A bedtime interval ends; or two routines overlap.
- **Expected vs actual**: Expected — rule-blocked apps stay shielded and each routine's shield is independent. Actual — rule apps un-shielded (list empty), bedtime shield dropped early.
- **Fix**: Use per-routine `ManagedSettingsStore(named:)` for bedtime, track which routines are active, and have the rule-sync port actually persist `apps.blockedBundleIdentifiers` before relying on it in `intervalDidEnd`.
- **Confidence**: certain-from-code (the keys are read but never written; single shared store).

### IOS-06 — `scheduleBedtime` ignores `RoutineWindow` and passes unvalidated `DateComponents`
- **Severity**: medium
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/ScreenTimeController.swift:48-60`; `RoutineWindow.swift:31,48-56`
- **What breaks**: The only tested, correct window logic (`RoutineWindow`, incl. `wrapsMidnight`, whole-day `start==end`, and `endMinutes==1440` unbounded) is **never connected** to `scheduleBedtime`, which takes raw `start`/`end` `DateComponents` straight into `DeviceActivitySchedule`. There's no validation, no min-duration check, and no split for the whole-day/unbounded cases the model supports. A caller bridging `RoutineWindow(endMinutes:1440)` to `DateComponents(hour:24)` relies on undocumented rollover; `start==end` yields a zero-length interval.
- **Trigger**: Scheduling any routine that isn't a well-formed intra-day `start<end` window.
- **Expected vs actual**: Expected — `RoutineWindow` semantics honored. Actual — dead code; arbitrary/edge inputs go straight to `DeviceActivitySchedule` (`nextInterval` may return `nil`, or produce an unintended 24 h/overnight interval).
- **Fix**: Add a `RoutineWindow → (intervalStart, intervalEnd)` bridge that validates and splits midnight-crossing/whole-day windows, and reject/repair invalid components before `startMonitoring`.
- **Confidence**: certain-from-code (no bridge exists); **[needs-Mac]** for exact `DeviceActivitySchedule` edge behavior.

### IOS-07 — Pairing request has no timeout; UI can hang on "Pairing…" forever
- **Severity**: medium
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/PairingClient.swift:63-85`; `PairingView.swift:51-54,72`
- **What breaks**: `claim` uses `URLSession.shared.data(for:)` with no `URLRequest.timeoutInterval` and no cancel. The button is `disabled(pairing || code.count != 6)` and only a `defer { pairing = false }` releases it — if the host is unreachable (DNS/timeout), the task hangs and the form stays locked on "Pairing…" with no cancel.
- **Trigger**: Pair against a wrong/offline address.
- **Expected vs actual**: Expected — user gets "Cannot reach the server" and can retry. Actual — indefinite spinner/disabled state (until the OS-level default timeout, if any, eventually fires).
- **Fix**: Set `request.timeoutInterval` (e.g. 15-30 s) and/or wrap in `Task` with cancellation tied to the button.
- **Confidence**: certain-from-code.

### IOS-08 — Alert delivery is fire-and-forget with no retry/backoff/queue; unpaired state drops silently
- **Severity**: medium
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/DeviceActivityMonitor.swift:27-42,63-69`
- **What breaks**: `report` does a single `dataTask` and only logs failures; no retry, no backoff, no persistence. In a `DeviceActivityMonitor`/`ShieldAction` extension the process may be torn down right after the callback, so a transient network failure or a kill means the alert is lost. Unpaired/empty-base-URL also just logs and returns — no user-visible signal, no durable queue.
- **Trigger**: Any alert while offline, or while the extension is being suspended; or any alert before pairing completes.
- **Expected vs actual**: Expected — alerts are at-least-once delivered or surfaced. Actual — silently dropped with only a `Logger` line.
- **Fix**: Add a bounded retry with exponential backoff, and (at minimum) surface "not paired" to the user; ideally persist a small outbox.
- **Confidence**: certain-from-code.

### IOS-09 — `AgentIdentityStore.save` is silent-no-op when the app group isn't provisioned; `synchronize()` is deprecated
- **Severity**: low
- **File**: `apps/child-ios/Sources/FamilyShieldAgent/AgentIdentityStore.swift:28-41`; `PairingView.swift:78`
- **What breaks**: `UserDefaults(suiteName:)` returns `nil` until the app-group entitlement exists, so every `defaults?.set` no-ops. `PairingView.pair` calls `AgentIdentityStore.save(claimed)` then reports success unconditionally — the UI shows "Paired" while nothing was persisted, and the extensions still log "not paired". `synchronize()` is deprecated and unnecessary.
- **Trigger**: Run the pairing flow before the Xcode wrapper adds the app-group capability (i.e., the current state).
- **Expected vs actual**: Expected — persisted identity or an explicit error. Actual — false "Paired" state.
- **Fix**: Make `save` return `Bool`/throw when the suite is unavailable and gate the success UI on it; drop `synchronize()`.
- **Confidence**: certain-from-code (partly documented in QA-IOS.md, but the silent-success UX is not called out).

### MAC-01 — Scaffold emits a `status.json` that reads as healthy/enforcing when it enforces nothing
- **Severity**: low
- **File**: `apps/agent-macos/Services/PortableStatus.cs:34-42`
- **What breaks**: The placeholder writer emits `{"state":"ok","paused":false,…}` every 60 s. Any consumer (parent dashboard, ops) reading `~/Library/Application Support/FamilyShield/status.json` would interpret the child as online *and not paused* while no rule sync, filtering, or enforcement exists. The README and comments are honest, but the emitted artifact itself is misleading. (Also: `Microsoft.Data.Sqlite`/`System.Reactive` are referenced in the csproj but unused — harmless, but signals "real agent" in the project file.)
- **Trigger**: Run the scaffold on a Mac; anything reads the status file.
- **Expected vs actual**: Expected — a status that can't be mistaken for enforcement. Actual — `state:"ok", paused:false`.
- **Fix**: Emit `"state":"scaffolding"` (or `"enforcing":false`) until the ported services land, and document the field as non-authoritative.
- **Confidence**: certain-from-code.

---

### Verified solid
- **Pairing contract matches the server exactly** — `POST /v1/devices/pair/claim` path, `{code, platform:"ios", model, osVersion, deviceName?}`, expected `201`, and the parsed fields `{token, childId, device.id, familyId, hmacSecret}` all line up with `services/api/src/routes/devices.ts:120-159` (`platform` enum includes `"ios"`; `hmacSecret:null`/missing → `nil` is the correct fail-closed behavior).
- **Alert body shape and enum values are correct** — `childId/title/body/severity/category/metadata` match `InternalAlertSchema` in `alerts.ts:18-36`; both emitted categories (`app_blocked`, `screen_time_exceeded`) and `severity:"warning"` are valid enum members (the *signature* is the bug — IOS-01, not the shape).
- **Shield extension subclassing is correct** — `ShieldConfigurationDataSource` and `ShieldActionDelegate` are classes (not protocols), and the `override func configuration(shielding:)` / `handle(action:for:completionHandler:)` signatures plus `.primaryButtonPressed`/`.secondaryButtonPressed` and `.none`/`.close` cases all match Apple's current API (only the `Label(color:nil)` calls are wrong — IOS-04).
- **`RoutineWindow` logic is sound and well-tested** — inclusive-start/exclusive-end, whole-day (`start==end`), and unbounded (`endMinutes==1440`) semantics are internally consistent and covered by 6 passing-when-run tests; the defect is that this code is never wired into `scheduleBedtime` (IOS-06).
- **macOS scaffold is honest at the source level** — `README.md`, `Program.cs`, and the csproj comments all clearly state "scaffolding, status-file-only, not compiled, nothing enforced" (the misleading part is only the emitted `status.json`, MAC-01).

One doc-drift note (not a runtime bug): `QA-IOS.md` and `IOS-BUILD-NOTES.md` still reference module/target `OSRAAgent` / `Sources/OSRAAgent/` / `Tests/OSRAAgentTests/` and "4/4 tests", while the actual `Package.swift` names the package/target `FamilyShieldAgent` and the two test files contain 13 test methods total.