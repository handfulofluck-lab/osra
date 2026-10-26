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

## Push and commands (updated 2026-10-25, roadmap 5.5 PR D, #372)

- **Push token:** the app registers for remote notifications at launch and again after pairing.
  `PushTokenRegistrar` uploads the APNs token as hex (`POST /v1/devices/:id/push-token`, device token, 204). It
  uploads only when the token or the paired device changed, and a failed upload is retried next time. "Re-pair
  this device" saves the new identity over the old one without unpairing, so the new device id alone triggers the
  upload for the new row. Unpairing forgets the upload.
- **Wake → drain:** a wake push (`{"w":"1"}`, no command in it, #319) runs `CommandDrainer.drainNow()` in
  `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. Opening the app does the same before it
  fetches the rules.
- **The drain:**
  - It polls `GET /v1/devices/:id/commands?ack=1` and acks every command.
  - `rules_updated`, `consent_revoked` and `consent_granted` fetch the rules, once per drain. A withdrawn consent
    then answers 428 and clears everything.
  - Any other command (lock, ring, …) is acked **`failed`** with `{"reason":"unsupported_on_ios"}`, so the parent
    sees why, not a silent "delivered". This was checked against the local API: the parent's history shows
    `lock: failed`, `rules_updated: acked`.
  - A 428 on the poll also syncs, which clears the rules.
- **App:** `UIBackgroundModes: remote-notification` in `Info.plist`, and `aps-environment` in the app's
  entitlements.
- **Server, fixed in this PR:**
  - Before, the wake went to Apple as `apns-push-type: alert` at priority 10 with nothing to show, and Apple can
    throttle or drop that. Now it goes as `apns-push-type: background` at priority 5, as Apple requires for
    `content-available`.
  - It goes to the child agent's topic (`APNS_DEVICE_BUNDLE_ID`), not the parent app's. Under the parent topic,
    Apple answers `DeviceTokenNotForTopic`, which the server reads as a dead token and clears. Unset, iPhones are
    not woken, which is better than losing their tokens.
  - `test/push.test.ts` pins both.
- **A token the server cleared (#383, roadmap 5.8):** the poll answers `X-Push-Token: on-file | none`. On `none`,
  `CommandDrainer` sends the token uploaded for this pairing again (`PushTokenRegistrar.resendAfterServerCleared`),
  past the "already uploaded" check, so push heals on the next drain instead of staying dead. Nothing is sent when
  nothing was uploaded for this pairing, and an older server without the header changes nothing.
- **Wake deadline (Claude's note 2 on #382):** iOS gives a woken app about 30 s. The wake path runs
  `CommandDrainer.drain(within: 25)`: past the deadline the drain is cancelled and the wake answers `.failed`; the
  next wake or launch drains again, because unacked commands stay in the queue.
- **Bedtime refused (Claude on #380):** if iOS refuses a new bedtime window, the old bedtime activity is stopped
  and its shield cleared, so the phone never keeps enforcing times the parent replaced.
- **Tests:**
  - `DeviceCommandsTests` (stubbed server): the command table; one fetch for several `rules_updated`, every
    command acked, `unsupported_on_ios`, a failed sync acked failed, 428; the token hex; once per token and device,
    re-pair the way the button does (no unpair in between), unpairing forgets the upload, retry after a failure,
    unpaired; `X-Push-Token: none` sends the stored token exactly once, `on-file` and an absent header send
    nothing, nothing to resend for a new pairing; the wake drain answers by its deadline even when the work ignores
    cancellation.
  - Live cases 7 (the token stored, then `alreadyUploaded`) and 8 (the ack-capable poll answers, and says `on-file` after case 7).
- **5.1 device checklist:**
  - a real APNs token is uploaded;
  - a parent rule change wakes a backgrounded, locked iPhone and its shields update without opening the app;
  - `APNS_DEVICE_BUNDLE_ID` is set to the permanent bundle id;
  - a wake whose drain runs past 25 s answers iOS `.failed` (the handler is in the App target, so no test pins
    it; Claude on #388), and the next wake drains what was left.

## Location (added 2026-10-25, roadmap 5.5 PR E, #372)

On the contract the Android agent already uses; no server change.

- **Collection:** `startMonitoringSignificantLocationChanges()` only. There is no continuous GPS and no
  `location` entry in `UIBackgroundModes` (`check-app-bundle.py` fails the build if one appears).
  Significant-change monitoring relaunches a suspended or terminated app with `.location`, and
  `didFinishLaunching` recreates the manager and restarts monitoring.
  - **Coarser than Android:** Android uploads every 30 s while moving and every 5 min when still. An iPhone
    reports when it moves a noticeable distance, typically about 500 m, and not more often than every few
    minutes. A parent sees the iPhone move in steps, not as a trail.
- **Upload:** each fix goes into a buffer in the app group (500 pings, oldest dropped first: the server's
  maximum batch) and is uploaded at once, inside `beginBackgroundTask`. The buffer is also flushed on the wake
  drain and when the app opens. `POST /v1/location/ping`, device token, body
  `{deviceId, childId, pings:[{lat, lng, accuracyM, timestamp}]}`, timestamps in ISO 8601 UTC.
  - **200/201:** stored, so the batch leaves the buffer. The route answers 201.
  - **428:** consent was withdrawn. Collection stops and the buffer is emptied. A rule sync answering 428 does
    the same, and a successful sync starts collection again.
  - **401:** kept, as the rest of the agent keeps its state.
  - **400 and other refusals:** the batch is dropped, so one bad ping cannot wedge the buffer.
  - **429, 5xx or offline:** kept for the next event.
- **Grant:** `POST /v1/devices/:id/telemetry {"locationGrant"}` at launch, after pairing and on every
  authorization change. Always maps to `background`, When In Use to `while_in_use`, and anything else to
  `none`. Reduced accuracy is not a fourth state: the pings carry their real `accuracyM`. The server uses the
  grant to fail a `locate_now` the phone cannot answer.
- **Permission:** the status screen explains what the parents see and asks for When In Use, then the upgrade
  to Always. The usage strings are in `Info.plist` and in `en.lproj` and `ar.lproj`. **The Arabic wording waits
  for Karim's review**, as in 3.1.
- **`locate_now`:** one `requestLocation()` at about 100 m, waiting up to 10 s. Without a fix, the last one
  under 5 minutes old is used as `cached` (Android's `MAX_CACHED_AGE_MS`). The point is uploaded, and the
  command is acked **`ok` with `detail.fix: fresh|cached` only after the server stored it**. A failed upload
  sends no ack, and the server offers the command again after 120 s (#231). With no fix the ack is `failed`
  with `location_unavailable`. Without permission it is `location_permission_missing`, or
  `background_location_missing` for When In Use only. These are Android's strings (#132). Several
  `locate_now` in one drain share one fix.
- **Tests:**
  - `LocationTests` (stubbed server, fake `LocationSource`): the grant for every authorization status; the
    telemetry body; When In Use asks for Always and reports the change; the body shape and ISO timestamp;
    428 stops collecting and empties the buffer; 400 drops the batch; 5xx, 429 and 401 keep it; the cap at
    500, oldest first; a ping added during an upload stays, both in the buffer and through `flush` (Claude's fault on #390); a new fix is uploaded; nothing is recorded when
    unpaired; monitoring starts only when paired and allowed; the rule sync drives collection; `locate_now`
    acks `ok` only after the server stored the point, sends no ack when the upload fails, takes a cached fix
    under 5 minutes and refuses an older one, and refuses with the Android reasons; the drain acks the fix,
    acks a refusal, skips the ack for an unstored point, and serves several `locate_now` with one fix.
  - Live case 9: the simulator is placed with `simctl location` and granted Always with `simctl privacy`. The
    grant is reported (202), a `locate_now` through Core Location answers `ok`, and `verify` reads the point
    back as the parent, attributed to the iPhone, with the device's grant `background`.
- **5.1 device checklist:**
  - significant-change updates on a real iPhone, moving between places;
  - a relaunch after termination delivers the new fix (the simulator can't relaunch on a location event);
  - the When In Use and Always prompts, in English and Arabic;
  - `locate_now` on a locked iPhone answers within the wake deadline.

## Rule sync (updated 2026-10-25, roadmap 5.5 PR C, #372)

The agent now fetches the parent's rules and stores them where the extensions read them.

- **When:** `RuleSyncer.syncNow()` runs when the app opens, right after pairing, and on a `rules_updated` command
  (PR D: a wake push drains the command queue).
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
   7. The push token is stored (204), and a second registration is skipped (PR D).
   8. The ack-capable command poll answers (PR D).
   9. Location (PR E): the grant is reported, and a `locate_now` through Core Location uploads the point
      the job placed the simulator at.
4. `scripts/live-api.mjs verify` logs in as the parent. `GET /v1/alerts` must hold exactly one
   `screen_time_exceeded` alert from this run (`metadata.run`) for that child, with a `deviceId`, and
   `GET /v1/devices` must list that device as `platform: "ios"` with `locationGrant: "background"`.
   `GET /v1/location/:childId/latest` must hold the simulator's coordinate, attributed to that device.

The simulator is booted (`simctl bootstatus -b`) before the code is minted, and case 1 waits for `GET /health` before it claims: on a cold boot the first request once reached the API about 50 s late, after the client's 30 s timeout. The claim itself is never retried, because a code is single-use.

It fails loudly (#361) in two ways. `OSRA_REQUIRE_LIVE=1` turns a missing input into a test failure; without
it, as in a local run, the cases skip. And the job asserts that 9 cases passed and none were skipped.
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
- ~~After pairing, the agent does not yet register an APNs push token~~ — done 2026-10-25 (5.5 PR D): see
  "Push and commands" above.
- ~~Routine/rules sync to the app group is still written by "the main agent app"~~ — done 2026-10-25 (5.5 PR C,
  #372): see "Rule sync" above.
