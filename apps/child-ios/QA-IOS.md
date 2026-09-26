# QA — iOS Child Agent (`apps/child-ios`) — static review

> Scope note: this is a **static review** (Windows host — no Swift toolchain can be
> installed here, and Screen Time frameworks only compile on macOS/iOS targets).
> `swift test` must be run on a Mac before shipping; the XCTest target exercises only
> the pure logic (`RoutineWindow`, pairing parser/normalizer/store). API signatures
> were previously verified against Apple's documentation JSON; this pass focused on
> logic and contract correctness.
>
> **Update 2026-09-18 (second pass):** the pairing flow landed — see
> "Pairing flow (added 2026-09-18)" below. The XCTest target now also covers
> `PairingClient.normalizeServerURL`, `PairingClient.parseClaimResponse` and
> `AgentIdentityStore` (11 new tests in `PairingTests.swift`). Still requires a
> macOS run of `swift test` and the Xcode wrapper project before shipping.

## Component checklist

| Component | Purpose | Reviewed | Result |
|---|---|---|---|
| `ScreenTimeController.swift` | Screen Time auth, app/web shields, bedtime scheduling | ✓ | OK with NOTEs (see below) |
| `ShieldConfiguration.swift` | Shield layout ("Blocked by FamilyShield", Ask parent / OK) | ✓ | OK after alert-reporter fix |
| `DeviceActivityMonitor.swift` | Bedtime interval shields + threshold alerts | ✓ | **2 bugs fixed** (below) |
| `RoutineWindow.swift` | Pure wrap-midnight window logic | ✓ | OK (inclusive start / exclusive end; whole-day when equal) |
| `FamilyShieldAgentTests.swift` | XCTest for RoutineWindow | ✓ | 4 tests, correct expectations |

## Bugs found & fixed (this pass)

1. **HIGH — every alert would be rejected by the API.** `AlertReporter` posted
   `{category, severity, message, ts}` to `/v1/alerts/internal`, but the endpoint
   requires `{childId, title, body, severity, category, metadata}` **and** the
   `X-FamilyShield-Signature` HMAC header (spec §12.3). Result: 400/401 for every iOS
   alert. **Fix:** reporter now builds the spec payload, requires `childId` (from the
   shared app-group store written at pairing, `agent.childId`), signs the body with
   CryptoKit `HMAC<SHA256>` when the paired secret is available
   (`agent.hmacSecret`), and logs non-2xx responses. Both call sites
   (`DeviceActivityMonitor.eventDidReachThreshold`,
   `FamilyShieldShieldActionDelegate.respond`) updated to the new signature.
2. **MEDIUM — bedtime end un-shielded rule-blocked apps.**
   `intervalDidEnd` set `store.shield.applications = nil`, wiping the parent's blocked-app
   shield whenever a bedtime interval ended. **Fix:** it now re-applies the rule-blocked
   token set persisted in the shared app group (`apps.blockedBundleIdentifiers`).

## Remaining NOTEs / known gaps (documented in code)

- `TokenResolver.categoryTokens` returns `[]` — category shields (gambling,
  pornography, ...) cannot resolve without a persisted `FamilyActivitySelection`
  registry; domain-level filtering via `blockedByFilter = .specific(domains)` works.
- Day encoding: FamilyShield rules use **1=Mon..7=Sun** (Android/API/desktop contract),
  while Foundation `DateComponents.weekday` is **1=Sun..7=Sat**. When routine schedules
  land on iOS, map `swiftWeekday = ruleDay % 7 + 1`. Currently only bedtime schedules
  (repeats daily, no weekday constraint) exist, so no runtime impact.
- `scheduleBedtime` registers `bedtime.<id>` per routine ID; per-routine `ManagedSettingsStore(named:)`
  stores would avoid cross-rule clobbering (documented at `intervalDidStart/End`).
- Extension targets (Shield UI, monitor) cannot be declared by SwiftPM — requires the
  Xcode wrapper project (unchanged from spec).
- Not verifiable here: compilation, Screen Time entitlement flow, extension lifecycle.

## Pairing flow (added 2026-09-18)

The iOS agent previously had **no enrollment path** — nothing wrote the shared
app-group keys (`agent.childId` / `agent.hmacSecret` / `agent.apiBaseURL`) that
`AlertReporter` reads, so every alert skipped at runtime. New components:

| File | Purpose |
|---|---|
| `PairingClient.swift` | `POST {base}/v1/devices/pair/claim` with `platform: "ios"` + device model/system version; pure `normalizeServerURL` and `parseClaimResponse` (tolerates `device` as object or string, `hmacSecret` null → nil); typed `PairingError` with user-facing messages |
| `AgentIdentityStore.swift` | Saves/loads/clears `AgentIdentity` in `UserDefaults(suiteName: "group.dev.familyshield.agent")` under the exact keys the extensions read (`agent.apiBaseURL`, `agent.childId`, `agent.hmacSecret`, plus `agent.deviceToken`/`agent.deviceId`/`agent.familyId` for future use) |
| `PairingView.swift` | SwiftUI form (server address, 6-digit code hard-limited to digits, optional device name) + `AgentRootView` status/re-pair switch; mirrors Android `PairingActivity` |
| `OSRAAgentApp.swift` | `@main` host-app entry; only executes once the Xcode wrapper project links the library into the host target |

Verified statically (no macOS toolchain on the review host): parser/normalizer are
pure Foundation and covered by 11 XCTest cases; the network call is a thin
`URLSession` wrapper mirroring the desktop `PairingService` contract.

Remaining pairing-related gaps:
- **Xcode wrapper project still to be committed** — must declare the host app target
  (using `OSRAAgentApp`), the three extension targets, the
  `com.apple.developer.family-controls` entitlement, and the app-group entitlement;
  replace the placeholder suite name `group.dev.familyshield.agent`.
- `deviceToken`/`hmacSecret` sit in plaintext UserDefaults (test-build acceptable,
  flagged in `AgentIdentityStore` docs) — move to Keychain with the app-group
  access group before shipping.
- After pairing, the agent does not yet register an APNs push token
  (`POST /v1/devices/:id/push-token`) — needed for parent push notifications.
- Routine/rules sync to the app group (`apps.blockedBundleIdentifiers`,
  `bedtime.blockedBundleIdentifiers`) is still written by "the main agent app"
  per the existing NOTEs — the rules-sync port lands with the wrapper project.
