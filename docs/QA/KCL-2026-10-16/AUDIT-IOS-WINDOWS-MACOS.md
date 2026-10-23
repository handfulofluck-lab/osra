# Child-agent audit: iOS / Windows / macOS (read-only, evidence-cited), 2026-10-16

Base: `main@fe1997c`.

## A) iOS agent — `apps/child-ios` — **2/10**

**Packaging reality.** `Package.swift:7` declares only a `.library` product; the repo contains **no `.xcodeproj`, `.xcworkspace`, `Info.plist` or `.entitlements`** (repo-wide `find` returns nothing). `OSRAAgentApp.swift:6-15` admits the `@main` "only runs when the Xcode wrapper project (still to be committed)" exists, and that wrapper must add the Family Controls + App Group entitlements and the Shield/ShieldAction/DeviceActivity extension targets. Without those extension targets, `FamilyShieldDeviceActivityMonitor` (`DeviceActivityMonitor.swift:123`) and the shield classes (`ShieldConfiguration.swift:14,51`) are never loaded by iOS. Nothing has ever been compiled on a device (`QA-IOS.md:3-8`, `IOS-BUILD-NOTES.md:4-6`); 17 XCTest methods cover only pure logic.

**Not stubbed, but dead code.** `ScreenTimeController` makes real `ManagedSettingsStore` calls — app shields (`ScreenTimeController.swift:30-39,43-52`), `webContent.blockedByFilter = .specific(domains)` (`:62-76`), `DeviceActivityCenter().startMonitoring` (`:85-106`). But a grep for `applyBlockedApps|applyWebFilter|scheduleBedtime|requestAuthorization|applySelection` outside that file returns **zero callers**. The only UI is pair/status (`PairingView.swift:92-128`). There is **no rule sync (`GET /v1/rules`), no command poll, no APNs/push-token registration** — so even if compiled and entitled, no parent rule would ever reach the device. `FamilyActivityPicker` exists only in a comment (`ScreenTimeController.swift:123`); the fallback `Application(bundleIdentifier:).token` (`:152`) is not a valid token source, and `categoryTokens(forNames:)` ignores its argument (`:156-159`).

| Feature | State | Mechanism / evidence | Main bypass / gap |
|---|---|---|---|
| App target + entitlements | **Missing** | SwiftPM lib only; no plist/entitlements | Cannot install |
| DeviceActivity / Shield extensions | **Missing** (classes exist) | `DeviceActivityMonitor.swift:123`, `ShieldConfiguration.swift:14,51` | No target → never invoked |
| App shields | **Stub-equivalent** | Real API, no callers, no picker | Rules never applied |
| Web filter | **Partial code / unwired** | `blockedByFilter` `:66-68`; no `NEFilterDataProvider` | Never called |
| Bedtime schedule | **Unwired** | `scheduleBedtime` `:85-106` | Never called |
| Pairing | **Implemented** | `PairingClient.swift:63-87` matches `services/api/src/routes/devices.ts:159` (returns `hmacSecret`) | Secrets in plaintext UserDefaults `AgentIdentityStore.swift:9-13` |
| Alerts (HMAC + deviceId) | **Implemented (fixed)** | `deviceId` added `DeviceActivityMonitor.swift:50-52`, HMAC `:59-62`, 3× retry `:70-90` | Only fires from extensions that have no target |
| Location / lock / ring / find / commands | **Missing** | No `CLLocationManager`, no command poll (grep) | — |

**Top gaps:** (1) no app/extension targets or entitlements; (2) no rules/command sync — controller is orphaned; (3) no FamilyActivityPicker, so tokens can't be obtained; (4) no location/commands at all. Versus Qustodio/Family Link (both ship Screen Time-backed app limits, web filtering, location), this is a design sketch, not an agent.

## B) Windows agent — `apps/agent-desktop` — **4/10**

**Runs as:** a user-mode `Microsoft.NET.Sdk.Worker` console exe with WinForms (`FamilyShield.Agent.csproj:1,6`); no `UseWindowsService`/`ServiceBase`, no autostart registration, no watchdog, no admin requirement (grep). Child can **End Task** it; `Program.cs:4` even restores direct internet on exit. Installer: none — "raw exe folder", unsigned (`PUBLISHING-READINESS.md:45-46`). `reset-proxy.bat` is shipped beside the exe (`csproj:23`) and is child-runnable.

| Feature | State | Mechanism / evidence | Main bypass |
|---|---|---|---|
| Web filter (HTTP) | **Implemented** | Titanium explicit proxy 127.0.0.1:8877 (`WebFilterProxy.cs:59,156-171`), allow→block→category (`LocalRuleStore.cs:281-292`), SafeSearch rewrite | Only plain HTTP |
| Web filter (HTTPS) | **Opt-in / effectively Missing** | Default: CONNECT tunnels pass untouched — **no `BeforeTunnelConnectRequest`** (grep; comments `:199-202,312-315`). Inspection only with env `FS_HTTPS_INSPECT=1` (`HttpsInterception.cs:25,35`), self-signed "FamilyShield Test Root" into CurrentUser\Root (`:540-546`), **upstream cert validation disabled** (`:491-495`) | HTTPS-everywhere web ⇒ domain blocks, pause and SafeSearch are no-ops by default; child can delete the user-store cert |
| Proxy pinning | **Partial** | WinINET HKCU only (`WebFilterProxy.cs:327-334`); self-heal every 60 s + 1/hr tamper alert (`RuleSyncService.cs:147-170`) | WinHTTP/apps ignoring proxy; `ProxyOverride` unmanaged (WIN-07 open, `TamperChecks.cs:405-417`); **child sets user env var `FS_SET_SYSTEM_PROXY=0`** and pinning is disabled (`:319-325,340-345` read `EnvironmentVariableTarget.User`); VPN detect-only (`RuleSyncService.cs:182-199`); fail-open on proxy start failure (`:97-116`) or handler exception (`:265-268`) |
| App blocking | **Partial** | 5 s poll + kill tree (`ProcessMonitor.cs:10,374-388`); WIN-05 fix matches name/exe name/PE OriginalFilename (`:287-315`) | Binaries without version info; elevated process (access denied swallowed `:310-313`, no alert); blocklist-pack path still name-only (`:252`); kill agent |
| Screen-time overlay | **Partial** | WIN-01 fixed: per-screen forms `LockOverlay.cs:560-569`, Alt+F4/SC_CLOSE suppressed `:693-712` | **New bug:** overlay has no owner state — `ScreenTimeEnforcer.Evaluate` calls `LockOverlay.Hide()` whenever not bedtime and under cap (`ScreenTimeEnforcer.cs:785-802`), so a parent `lock`/`pause`/`wind_down` overlay (`RuleSyncService.cs:227,238,328`) is auto-dismissed within ≤60 s. Also Task Manager, new virtual desktop, process kill |
| Bedtime | **Partial** | WIN-02: `LockWorkStation` + overlay each 60 s (`ScreenTimeEnforcer.cs:775-783`) | Child's own password re-enters; overlay PIN is `DESKTOP_PARENT_PIN` env or **"0000"** (`:723-724`, `RuleSyncService.cs:10-11`) — not synced from parent (no DTO field); compared client-side `LockOverlay.cs:659`; kill agent |
| Screen-time counting | **Fixed (WIN-03)** | Single foreground accumulator `ProcessMonitor.cs:431-449`; time_limit branch no longer writes usage `:141-153`; excludes LockApp/LogonUI `:434-439` | No `GetLastInputInfo` idle detection; clock rollback resets (WIN-10 open, `DateTime.Now`) |
| Commands | **Implemented** | 60 s poll: pause/resume(_internet), lock/unlock, ring (`Console.Beep`×5 `:350-364`), bonus_time, wind_down, rules_updated | **No `locate`** / no geolocation anywhere (grep) |
| SOS hotkey | **Implemented, off by default** | Shift+F11 `RegisterHotKey`, gated `FS_SOS_HOTKEY=1` (`SosHotkey.cs:17-40`, `Program.cs:40-43`) | — |
| Tamper detection | **Partial** | proxy-disabled + VPN alerts (`TamperChecks.cs`) | No detection of process kill, cert removal, env-var override, clock change; no uninstall protection |
| Secrets | **Weak** | plaintext `agent.config.json` beside exe (`AgentConfig.cs:555`), WIN-11 open | Child reads JWT/HMAC |

Tests: 134 `[Fact]/[Theory]` across 16 files (docs claim 161), all pure-logic seams; no integration coverage of proxy/overlay.

**Top gaps:** (1) HTTPS unfiltered by default and inspection is an insecure env-var hack; (2) user-mode killable process, no service/installer/signing; (3) enforcer auto-hides parent locks; (4) hardcoded "0000" PIN; (5) per-user env vars the child controls disable enforcement. Qustodio runs a signed service with a kernel/driver-level filter and tamper-protected uninstall; this agent is a credible dev prototype but trivially defeated by any motivated child.

## C) macOS — `apps/agent-macos` — scaffolding only (0/10 as an agent)

`Program.cs` (6 lines) runs `PortableStatus.RunAsync()`; `PortableStatus.cs:34-44` writes `~/Library/Application Support/FamilyShield/status.json` every 60 s with `state:"scaffolding", enforcing:false` (MAC-01 addressed). csproj pulls Sqlite/Reactive, unused. README (`:3-7,58-66`) honestly says never compiled, "status file I/O only". No pairing, sync, filtering, Screen Time, or telemetry.

## Store-readiness blockers (`docs/test-guides/PUBLISHING-READINESS.md`)

- **Play (`:25-39`):** debug-signed (no upload keystore/AAB); no privacy policy URL; data-safety form not filled; IARC rating not done; accessibility-service prominent disclosure + justification video needed; hardcoded dev secrets in `start-backend.bat` (rotate JWT/HMAC, set VAULT_KEY); FCM not configured; 16 KB page-size unverified; no internal-track run yet.
- **Windows (`:41-48`):** no code-signing cert (SmartScreen warning); no installer (MSIX/Inno); HTTPS root CA is self-signed opt-in — needs MDM/GPO provisioning; privacy disclosure of local proxy/inspection.
- **App Store:** the document's scope is "Android (Play) + Windows desktop" (`:2`) — **iOS is not assessed at all.** From code, the de facto blockers are: no Xcode project/entitlements, Family Controls distribution entitlement (requires Apple approval), no extension targets, no privacy manifest, and nothing compiled.

Noted doc drift: `IOS-BUILD-NOTES.md` references module `OSRAAgent`/`OSRAIOS.xcodeproj` that do not exist (actual target is `FamilyShieldAgent`).
