# iOS Child Agent — Build Notes (Feature #25 artifacts)

> Scope: `apps/child-ios` (Swift package `OSRAAgent`, iOS 16+). Host during the
> world-class upgrade was **Windows** — no Swift/Xcode toolchain exists here, so this is a
> static-review + handoff document. Everything below must be executed on a Mac before
> shipping; nothing iOS-side was compiled in this phase.

## 1. What compiles where

| Component | File | Where it compiles |
|---|---|---|
| `RoutineWindow` (pure wrap-midnight window math) | `Sources/OSRAAgent/RoutineWindow.swift` | Anywhere — it has **no Apple imports**; exercised by the XCTest target via `swift test` on a Mac. |
| `ScreenTimeController` (FamilyControls auth, app/web shields, bedtime schedules) | `Sources/OSRAAgent/ScreenTimeController.swift` | Only against the **iOS SDK on macOS** (`ManagedSettings`, `FamilyControls`, `DeviceActivity` are iOS-only frameworks; guarded by `#if canImport`). |
| `ShieldConfiguration` (shield UI + Ask-parent action) | `Sources/OSRAAgent/ShieldConfiguration.swift` | iOS SDK only; this type must be embedded in a **ShieldConfiguration extension target** to be usable by the system. |
| `DeviceActivityMonitor` (bedtime intervals, threshold events, `AlertReporter`) | `Sources/OSRAAgent/DeviceActivityMonitor.swift` | iOS SDK only; must be embedded in a **DeviceActivityMonitor extension target**. |
| XCTest suite (4 `RoutineWindow` tests) | `Tests/OSRAAgentTests/OSRAAgentTests.swift` | `swift test` on a Mac — no device or simulator required. |

SwiftPM can host the library and tests, but **extension targets cannot be declared in a
package** — the production binary requires the Xcode wrapper project (section 2). Until
that exists, `swift test` is the only executable verification.

## 2. Xcode wrapper-project steps (do once on a Mac)

1. **Create the Xcode project** (`File ▸ New ▸ Project ▸ App`, iOS 16+, SwiftUI or UIKit
   shell — the agent's UI is intentionally minimal: pairing + "protection active" notice).
2. **Add the Swift package** `apps/child-ios` (or drag the folder in) so the app target
   links `OSRAAgent`.
3. **Add two new targets** of type `Extension`:
   - `OSRAShieldConfig` — **ShieldConfiguration Extension**. Assign
     `ShieldConfiguration.swift` (the `OSRAShieldActionDelegate`) to this target.
   - `OSRAMonitor` — **DeviceActivityMonitor Extension**. Assign
     `DeviceActivityMonitor.swift` to this target.
   - Both extensions must link the same `OSRAAgent` package target.
4. **Capabilities on all three targets**: **Family Controls**
   (`com.apple.developer.family-controls`) — without it `AuthorizationCenter.requestAuthorization`
   fails at runtime (NOTE in `ScreenTimeController.requestAuthorization`).
5. **App Groups** on all three targets: `group.<team-id>.familyshield` — the shared store
   (`UserDefaults(suiteName:)` / keychain access group) that carries `agent.childId`,
   `agent.hmacSecret`, and `apps.blockedBundleIdentifiers` between app and extensions.
6. Set the **same bundle-id prefix** and team on app + extensions, sign with a real
   (paid) profile — Family Controls and app groups do not work with free provisioning in
   a child-agent configuration.
7. Device, not just simulator: shield UI rendering and FamilyControls authorization
   prompts behave differently in the simulator; do the final pass on a physical iPhone.

## 3. Pairing flow — state and TODOs

**Done (Phase QA, see `apps/child-ios/QA-IOS.md`):**
- `AlertReporter` now sends the spec payload `{childId, title, body, severity, category,
  metadata}` to `POST /v1/alerts/internal` and signs the body with `HMAC<SHA256>`
  (`X-FamilyShield-Signature`, secret from the shared store key `agent.hmacSecret`).
  Previously every alert was a guaranteed 400/401 (wrong shape, no signature) — **fixed**.
- Both call sites updated: `DeviceActivityMonitor.eventDidReachThreshold` (bedtime/
  threshold alerts) and `OSRAShieldActionDelegate.respond` (Ask-parent taps).
- Bedtime-end no longer wipes parent rule shields (re-applies `apps.blockedBundleIdentifiers`).

**TODO before the app is usable:**
1. **App-group provisioning**: pairing must write `agent.childId` + `agent.hmacSecret`
   into the `group.<team-id>.familyshield` suite. Until the Xcode project and entitlements
   exist (step 2/5 above) there is no suite to write to — the reporter currently logs
   "childId unknown (agent not paired)" and skips.
2. **Claim/pairing UI**: a screen that takes the parent app's pairing code (same flow as
   Android/desktop: device registers, receives device JWT + HMAC secret, persists both).
3. **Category-token registry**: `TokenResolver.categoryTokens` returns `[]` — category
   shields need a persisted `FamilyActivitySelection`; domain-level filtering works today.
4. **Weekday mapping**: rules use 1=Mon..7=Sun vs Foundation 1=Sun..7=Sat
   (`swiftWeekday = ruleDay % 7 + 1`) once routine schedules land on iOS.
5. Per-routine `ManagedSettingsStore(named:)` stores to avoid cross-rule clobbering.

## 4. Manual verification on a Mac (checklist)

```bash
# 1. Pure-logic suite (no device needed) — must pass 4/4:
cd apps/child-ios && swift test

# 2. Wrapper project builds clean (iOS 16+ destination):
xcodebuild -project OSRAIOS.xcodeproj -scheme OSRAAgent -destination 'generic/platform=iOS' build

# 3. On a physical device (iOS 16+):
#    - app launches, pairing code accepted, childId/hmacSecret land in the app group;
#    - Screen Time authorization prompt appears and grants (.child);
#    - blocked app shows "Blocked by OSRA" shield with Ask parent / OK;
#    - "Ask parent" tap POSTs a signed alert (check API log for 202, not 401);
#    - bedtime interval start shields apps, end restores rule shields;
#    - background the app → DeviceActivityMonitor still fires at the threshold.
```

Any failure in step 3 that also reproduces on the Android agent's equivalent flow is a
spec bug, not an iOS bug — file it against the API contract first.
