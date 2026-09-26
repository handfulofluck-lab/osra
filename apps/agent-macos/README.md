# FamilyShield Agent — macOS (Feature #25 scaffolding)

> Status: **proven scaffolding**. This folder exists so the macOS agent *builds and runs*
> on a Mac today. No Mac was available during the world-class upgrade (Windows-only host),
> so nothing here has been compiled — the csproj was verified by XML inspection only
> (see "How far the test build goes" below). Everything platform-bound is documented
> honestly rather than faked.

## What is here

| Path | Purpose |
|---|---|
| `FamilyShield.Agent.MacOS.csproj` | `net8.0-macos` (Microsoft.NET.Sdk, nullable + implicit usings). References **Microsoft.Data.Sqlite 8.0.6** and **System.Reactive 6.0.1** only — deliberately **no Titanium.Web.Proxy**: macOS traffic filtering is entitlement-bound via NetworkExtension, not a user-space WinINET proxy. |
| `Services/PortableStatus.cs` | The one working service: writes `~/Library/Application Support/FamilyShield/status.json` every 60 s with `state` / `paused` / `updatedAt` placeholders. Proves the folder compiles, runs, and persists state on macOS. |
| `Program.cs` | Entry point that starts `PortableStatus`. |
| `scripts/build-macos.sh` | `dotnet publish -c Release -r osx-arm64` (default) or `osx-x64`, self-contained, to `dist/<rid>/`. |
| `scripts/run-macos.sh` | `dotnet run` for dev (framework-dependent). |

## Porting map — `apps/agent-desktop` → macOS

The Windows agent (`apps/agent-desktop`, `net8.0-windows`) is the reference. Column 2
is exactly what survives the port and what must be replaced.

| Desktop service | macOS disposition |
|---|---|
| `Services/LocalRuleStore.cs` | **Portable as-is.** SQLite via Microsoft.Data.Sqlite + `System.Text.Json`; zero Win32/WinINET/WinForms usage. Copy the file verbatim. |
| `Services/TelemetryUploader.cs` | **Portable minus one block.** The 5-minute batch upload core (URL log, app-usage rows, activity events) is pure. The trailing `BatteryStatus` class P/Invokes `kernel32.dll!GetSystemPowerStatus` — replace with an `IOPSCopyPowerInfo` P/Invoke or delete the field. Any WinForms pause overlay must be re-created (see `LockOverlay`); this service itself does not reference WinForms. |
| `Services/RuleSyncService.cs` | **Portable minus Win32 seams.** The 60 s poll loop, command dispatch (`pause_internet`, `bonus_time`, `wind_down`, …) and rule merging are pure. It currently wires Windows-specific test/production seams that need macOS equivalents: `TamperChecks.RegistryReader` (registry) → NESettings/`SCDynamicStoreCopyValue` proxy readback; `AgentStatus.ProxyRunning` → `NEInternetFilterManager` status; `SosHotkey` (`RegisterHotKey`, Shift+F11) → `NSEvent.addGlobalMonitorForEvents` (requires Accessibility permission) or a menu-bar SOS button. |
| `Services/ApiClient.cs`, `AgentConfig.cs`, `Dtos.cs`, `TimeWindows.cs`, `PauseGate.cs` | **Portable pending review** — no Windows-only APIs observed; expected to copy with namespace changes. `PauseGate` logic (pause vs bedtime vs always-allowed precedence) is pure. |
| `Services/WebFilterProxy.cs` | **Not portable.** Titanium.Web.Proxy + WinINET system-proxy pinning (`InternetSetOption`). Replace with a NetworkExtension **content-filter provider** (see entitlements below) or drop web filtering in favour of Screen Time web shields. |
| `Services/HttpsInterception.cs` | **Not portable** (cert injection into Windows user store). macOS equivalent: install a root CA into the System keychain (user-consented, documented risk — same policy as Windows `FS_HTTPS_INSPECT=1`). |
| `Services/ScreenTimeEnforcer.cs` | **Replace with Apple's frameworks.** On macOS 13+ use `FamilyControls` (`AuthorizationCenter.requestAuthorization`) + `ManagedSettings` (`ManagedSettingsStore` application/web shields) — same architecture as `apps/child-ios`. |
| `Services/ProcessMonitor.cs` | **Partial.** App-usage counters need a process enumerator — replace WMI/registry paths with `libproc` (`proc_listpids`) or `ps` parsing; VPN-interface detection via `SystemConfiguration.SCNetworkInterfaceCopyAll`. |
| `Services/LockOverlay.cs`, `PairingDialog.cs` | **Rewrite UI.** Avalonia (cross-platform, pairs with the ported services) or AppKit/NSWindow. WinForms does not exist on macOS. |
| `Services/SafeSearch.cs` | **Portable** (URL rewriting rules) once the filter pipeline it plugs into is re-platformed. |
| `Services/TamperChecks.cs` | **Rewrite.** Registry proxy readback → NESettings/proxy plist readback; keep known-VPN process-name matching. |

## Entitlement requirements (why this can't be "just compile it")

macOS gatekeeping makes the filtering half entitlement-bound, which is the real reason
this phase ships scaffolding + scripts instead of a compiled agent:

- **NetworkExtension content filter** — web/domain filtering outside Safari requires
  `com.apple.developer.networking.networkextension` with the **Content Filter**
  capability and a *paid* Apple Developer provisioning profile. The approved app
  installs an `NEContentFilter`/`NEFilterDataProvider` extension; without the
  entitlement the API exists but the extension never activates.
- **Screen Time path (macOS 13+)** — app shields, web shields and schedules via
  `FamilyControls` + `ManagedSettings` require the **Family Controls** capability
  (`com.apple.developer.family-controls`). This is the lower-friction path and matches
  the iOS agent architecture in `apps/child-ios`; it does not give raw traffic
  inspection, only token-based shields.
- **App group** — `group.<team-id>.familyshield` for the shared pairing store
  (`agent.childId`, `agent.hmacSecret`) between the agent and its extensions.
- **Accessibility** — only needed if you keep a global SOS hotkey / overlay input
  monitoring; prompt the user from System Settings.

## How far the test build goes

1. On a Mac with the .NET 8 SDK: `bash scripts/build-macos.sh` (or `osx-x64`) publishes a
   self-contained `FamilyShield.Agent.MacOS` binary; `bash scripts/run-macos.sh` starts it
   and creates/updates `~/Library/Application Support/FamilyShield/status.json` every 60 s.
2. That is the entire verified scope: **status file I/O only**. No pairing, no rule sync,
   no filtering, no telemetry — those arrive service-by-service per the porting map.
3. csproj XML inspected on Windows; `net8.0-macos` compilation is Mac-only by definition
   (Apple SDK bindings). Do not attempt to build this folder on Windows.

## Next steps (in order)

1. Copy `LocalRuleStore.cs` verbatim; add an xunit project mirroring `apps/agent-desktop/tests`.
2. Port `TelemetryUploader.cs` with the battery block behind `#if __MACOS__`.
3. Port `RuleSyncService.cs` behind the documented macOS tamper/SOS seams.
4. Add the FamilyControls/ManagedSettings shield layer (reuse `apps/child-ios` design).
5. Only then pursue NetworkExtension content filtering if raw traffic inspection is
   still required.
