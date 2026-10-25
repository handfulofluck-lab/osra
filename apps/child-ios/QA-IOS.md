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

## Build status (updated 2026-10-24, roadmap 5.5, #372)

**The agent now builds as an installable app with its three extensions, on the GitHub macOS runner.**
`ios-ci.yml` (macOS 26, the newest Xcode on the image) does this on every change under `apps/child-ios/`:

1. Builds the `FamilyShieldAgent` package for the simulator and runs its XCTest target, as before.
2. Generates `OSRAAgent.xcodeproj` from `project.yml` with XcodeGen (version and checksum pinned in the
   workflow). The project is never committed; review `project.yml`.
3. Builds the `OSRAAgent` scheme **unsigned** (`CODE_SIGNING_ALLOWED=NO`, Release) for
   `generic/platform=iOS Simulator` and `generic/platform=iOS`.
4. Runs `scripts/check-app-bundle.py` on both builds. It fails the job unless:
   - `PlugIns/` holds exactly the three `.appex` bundles;
   - each `.appex` has the expected `NSExtensionPointIdentifier` and `NSExtensionPrincipalClass`, and
     its binary defines that class;
   - all four `.entitlements` files carry `com.apple.developer.family-controls` and
     `group.dev.familyshield.agent`. An unsigned build embeds no entitlements, so this reads the source files.

| Target | Kind | Bundle id (placeholder) | Principal class | Extension point |
|---|---|---|---|---|
| `OSRAAgent` | host app (`App/`, `@main` `OSRAAgentApp`) | `dev.familyshield.agent` | — | — |
| `OSRAAgentMonitor` | app extension (`Extensions/Monitor/`) | `dev.familyshield.agent.monitor` | `FamilyShieldDeviceActivityMonitor` | `com.apple.deviceactivity.monitor-extension` |
| `OSRAAgentShieldConfiguration` | app extension (`Extensions/ShieldConfiguration/`) | `dev.familyshield.agent.shield-configuration` | `FamilyShieldConfigurationDataSource` | `com.apple.ManagedSettingsUI.shield-configuration-service` |
| `OSRAAgentShieldAction` | app extension (`Extensions/ShieldAction/`) | `dev.familyshield.agent.shield-action` | `FamilyShieldShieldActionDelegate` | `com.apple.ManagedSettings.shield-action-service` |

- **The principal classes stay in the package.** They are `public` and carry `@objc(<name>)`, so the
  runtime finds them under the unqualified name in `Info.plist`. Each extension's one source file
  refers to its class, so the linker keeps it in that extension's binary.
- **The extension point ids** match the values Apple's engineers give on the developer forums, and
  App Store Connect rejects any other value (ITMS-90349), for example
  `com.apple.deviceactivity.monitor` without `-extension`, or the shield action id under `ManagedSettingsUI`.
  The first signed upload is where Apple validates them; until then, the bundle check pins them.
- **Placeholders, not final:** the bundle ids and the app group. The maintainer chooses the permanent
  ids before App Store Connect, as for Play. The repository is public, so `DEVELOPMENT_TEAM` stays empty
  and no team id, provisioning profile or certificate is ever committed.

**Still needs a signed build (5.1, the Apple developer account and the Family Controls entitlement):**
running on a real iPhone, the Screen Time authorization prompt, an extension actually being launched by
the system, and TestFlight (5.6). The device token and HMAC secret are in the Keychain since PR B (see
"Remaining pairing-related gaps"). Next PRs on this row: rule sync into the app group, and APNs token registration. The iOS pairing client is ported after the
pairing-approval change lands, so it isn't ported twice.

## Rule sync (updated 2026-10-25, roadmap 5.5 PR C, #372)

The agent now fetches the parent's rules and stores them where the extensions read them.

- **When:** `RuleSyncer.syncNow()` runs **only when the app opens and right after pairing**, and a child
  rarely opens it. PR D (APNs `rules_updated`) closes that gap.
- **How:** `GET /v1/rules/:childId` with the device token (`RuleSyncClient`), the same contract as the Android
  agent. `RuleSet` decodes the server's shape and ignores fields it doesn't use.
- **Stored** (`RuleStore`, app-group `UserDefaults`):
  - the blocked apps (`action: "block"`), the allowed apps (`action: "allow"`) and `alwaysAllowedApps`;
  - the bedtime window, blocked domains and categories;
  - the routines, with their days converted and their own `blockedApps` / `allowedApps`.
- **Days:** rules use 1=Mon..7=Sun and Foundation uses 1=Sun..7=Sat, so `Weekday.swiftWeekday(ruleDay:)` is
  `ruleDay % 7 + 1`. Anything outside 1...7 is dropped.
- **What a running interval shields** is a pure function, `ShieldPolicy.decide`, with SwiftPM rows. It follows
  Android's `RuleEngine`:
  - **bedtime**, and a routine with `allowedApps`, shield **everything except** the allowed apps:
    `alwaysAllowedApps`, `action: "allow"`, the routine's own `allowedApps`, and the dialer
    (`com.apple.mobilephone`, as Android's essential-apps rule #165);
  - a routine with only `blockedApps` shields those;
  - a routine shields nothing on a day it doesn't run.
- **Enforcement** needs Screen Time authorization (`ScreenTimeController.applyRules`):
  - The monitor applies the policy with `.all(except:)`. A bundle id with no token stays shielded, which fails
    closed.
  - Bedtime is one daily activity. Each routine is also **one daily activity** (`routine.<index>`,
    `RoutinePlan`), and the weekday check runs when the interval starts. An overnight routine is judged by the day
    it started on. So a seven-day routine costs one activity against `DeviceActivityCenter`'s per-app cap, not
    seven.
  - Any activity the system refuses is recorded in one place (`RuleStore.unscheduled()`) and logged once.
- **Stopping never leaves a shield on.** A running interval keeps its shield in its own named store. Before
  monitoring stops (stale routines, or a 428), each store is cleared first (`ActivityTeardown`).
- **Failures:**
  - **428** (consent withdrawn): every stored rule and every shield is removed.
  - **401** (the device was removed) and any other failure: the last rules stay in force, as on Android
    (`RuleRepository.refresh` keeps its cached rules on every failure).
  - Unpairing clears the rules.
- **Leftovers from a previous install:** Keychain items outlive deleting the app, while the app group does not. At
  launch, `AgentIdentityStore.clearOrphanedSecrets()` deletes a token and secret that no identity owns. A paired
  phone, including one paired by an older build, is never touched.
- **Tests:**
  - `RuleSyncTests`: the weekday table, the server shape, the stored keys, the `ShieldPolicy` rows (bedtime,
    allow-list routine, block-list routine, off-day, overnight start day, unknown activity), one activity per
    routine, clear-before-stop order, and sync outcomes 200 / 428 / 500 / not paired.
  - `AgentIdentityStoreTests` and the hosted `KeychainTests`: the orphan clean-up.
  - Live case 6: the rules the parent set through the API sync with the device token.
- **5.1 device checklist** (needs a signed build):
  - bedtime shields every app but the allowed ones, and the Phone app stays reachable under `.all(except:)`;
  - a daily routine shields only on its weekdays, overnight included;
  - a 428 during bedtime removes the shield;
  - the on-device `FamilyActivityPicker` for category shields, which comes with the signed build (Claude, #380).

## Live API test (updated 2026-10-24, roadmap 5.5 PR A2, #372)

A static review once missed that every iOS alert would be refused (400/401), so the agent is now tested
against **our real API**, on every iOS change, on changes to the three server files it depends on
(`routes/devices.ts`, `routes/alerts.ts`, `lib/internalAuth.ts`), and nightly. Job `live-api` in
`.github/workflows/ios-ci.yml`:

1. Starts Postgres 16, Redis (`noeviction`) and the API from this checkout on the macOS runner (no Docker
   there). The JWT, HMAC and vault secrets are generated for the run with `openssl rand` and masked.
2. `scripts/live-api.mjs setup` seeds through the API, as `services/api/scripts/e2e.mjs` does: the seeded
   parent logs in, adds a child with consent, and mints a pairing code. The inputs reach the tests as
   `TEST_RUNNER_OSRA_TEST_*` variables. The code is masked in the log.
3. `FamilyShieldAgentIntegrationTests` (`IntegrationTests/LiveAPITests.swift`, scheme
   `OSRAAgentIntegration`) runs inside the ad-hoc signed simulator app, so the identity goes through the
   real Keychain. Its cases, in order:
   1. `PairingClient` claims the code with `platform: "ios"`. The identity is saved and read back through
      `AgentIdentityStore`.
   2. A signed `screen_time_exceeded` alert from `AlertReporter` gets **201**.
   3. The same bytes again get **401 `replay`**.
   4. One changed body byte gets **401 `invalid_signature`**.
   5. A request signed 600 s ago gets **401 `stale_timestamp`**.
   6. The rules the parent set in `setup` sync with the device token into the app group (PR C).
4. `scripts/live-api.mjs verify` logs in as the parent. `GET /v1/alerts` must hold exactly one
   `screen_time_exceeded` alert from this run (`metadata.run`) for that child, with a `deviceId`, and
   `GET /v1/devices` must list that device as `platform: "ios"`.

The simulator is booted (`simctl bootstatus -b`) before the code is minted, and case 1 waits for `GET /health` before it claims: on a cold boot the first request once reached the API about 50 s late, after the client's 30 s timeout. The claim itself is never retried, because a code is single-use.

It fails loudly (#361) in two ways. `OSRA_REQUIRE_LIVE=1` turns a missing input into a test failure; without
it, as in a local run, the cases skip. And the job asserts that 6 cases passed and none were skipped.
`AlertReporter` gained `makeRequest`/`send` for the tests. `report` uses the same builder and keeps its
fire-and-forget retry.

**Not covered:** a real iPhone, the system launching the extensions, and APNs (5.1). Also the pairing
change in osra-security#3 PR 2 (the parent approves each claim): with the path filter, that PR runs this
job, so the iOS client gets ported in the same change.

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
  land on iOS, map `swiftWeekday = ruleDay % 7 + 1`. Done 2026-10-25 (5.5 PR C): `Weekday.swiftWeekday(ruleDay:)`,
  with tests.
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
| `OSRAAgentApp.swift` | `@main` host-app entry; moved to `App/` (the `OSRAAgent` target) on 2026-10-24, #372 |

Verified statically (no macOS toolchain on the review host): parser/normalizer are
pure Foundation and covered by 11 XCTest cases; the network call is a thin
`URLSession` wrapper mirroring the desktop `PairingService` contract.

Remaining pairing-related gaps:
- ~~Xcode wrapper project still to be committed~~ — done 2026-10-24 (#372): `project.yml`, see
  "Build status" above. The app group `group.dev.familyshield.agent` is still a placeholder.
- ~~`deviceToken`/`hmacSecret` sit in plaintext UserDefaults~~ — done 2026-10-24 (5.5 PR B, #372):
  both are Keychain generic-password items (`KeychainSecretStore`, service `dev.familyshield.agent`)
  in the app group's access group, `AfterFirstUnlockThisDeviceOnly`, so the extensions can read them
  while the phone is locked and no backup carries them. The ids stay in app-group `UserDefaults`.
  `AgentIdentityStore.load()` and `hmacSecret()` move an older build's plaintext copies into the
  Keychain and delete them only once the Keychain holds them. Two test sets:
  - `Tests/…/AgentIdentityStoreTests` (SwiftPM, in-memory store): save, load, clear, the migration from
    the app and from the extension path, a stale plaintext copy, a refused write. The unsigned SwiftPM
    bundle cannot use the Keychain at all (`errSecMissingEntitlement`, -34018, measured in CI).
  - `HostedTests/KeychainTests` (target `OSRAAgentHostedTests`, run inside the ad-hoc signed simulator
    app): the real Keychain with the production access group, including that the stored item is
    `AfterFirstUnlockThisDeviceOnly` in `group.dev.familyshield.agent` and that an overwrite leaves one item.
  Still needs a signed device build (5.1): an extension actually reading the item the app wrote.
- After pairing, the agent does not yet register an APNs push token
  (`POST /v1/devices/:id/push-token`) — needed for parent push notifications.
- ~~Routine/rules sync to the app group is still written by "the main agent app"~~ — done 2026-10-25 (5.5 PR C,
  #372): see "Rule sync" above.
