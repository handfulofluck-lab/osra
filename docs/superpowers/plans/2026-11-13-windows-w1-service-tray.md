# Windows W1 Service + Tray Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. K31 implements in this session; the exposed subagent model alias does not satisfy the maintainer's K3.1 Pro requirement, so no subagents are used.

**Goal:** Split the Windows agent into a LocalSystem service and per-user tray, preserve existing enforcement and pairing, and remove Release environment overrides while adding the ADR-0034 client identity and capability report.

**Architecture:** Convert the existing `FamilyShield.Agent.csproj` into the shared library and add two thin hosts, `OSRA.Service` and `OSRA`. The service owns network/rule state, process enforcement, telemetry and supervision; the tray owns pairing and all interactive UI. A per-interactive-session named pipe has an ACL for SYSTEM and that session's user, server-side verification of the client PID/session/SID, strict typed messages, and no credential fields.

**Tech Stack:** .NET 8, C# 12, existing generic host/WinForms/xunit/HttpClient, `Microsoft.Extensions.Hosting.WindowsServices` 8.0.0 (the only new package), the .NET shared-framework `System.IO.Pipes.AccessControl` APIs, existing Node/pnpm API suites and GitHub Actions.

**Spec:** `docs/adr/0041-one-family-plan-and-computer-downloads.md` D5–D6; `docs/adr/0034-capability-report-and-version-gate.md` decisions 1, 2 and 4; #623 comment 6854871267, approved with answers in #623 comment 6859234364.

## Global Constraints

- Keep internal namespaces/project identifiers. User-facing names are `OSRA Service` and `OSRA`; no mass rename and no Arabic edits.
- Production API is compiled as `https://api.osratech.com`. Only Debug reads `API_BASE`, `DEVICE_JWT`, `DEVICE_ID`, `CHILD_ID`, `INTERNAL_HMAC_SECRET`, `DESKTOP_PARENT_PIN` and the legacy proxy environment overrides.
- W1 adds no plaintext-PIN path. The existing local config shape remains for compatibility, but PIN never crosses the pipe or network and is never logged. PBKDF2 migration is W1b, not this PR.
- W2 DNS/firewall/proxy removal, W3 MSI/service-recovery/signing, W4 updater and #657 presentation remain separate. W1 publishes an unsigned artifact and does not claim production signing, installed-directory ACLs or publisher verification.
- Do not start a service, pair a real family, lock a session, sound an alert or enable a hotkey on the development PC. Tests substitute every OS boundary.
- `child_account_admin` is `granted` for the interactive administrator and `missing` for a Standard user. It is computed for the child/tray user, never SYSTEM. The generic missing-grant list must not present the safe Standard setup as a fault; D5's administrator warning is the positive-report case. `capabilities.client.flavour` uses the existing `dev` enum; the header uses `agent-desktop/<version>+<build> (windows)`.
- Branch only from current `main`, never force-push or merge. One PR for #623; run all relevant gates before marking it ready and enable auto-merge rather than merging directly. Label it `risk:R3` for pipe ACLs, OS-derived identity and process launch.

**Claude's review notes (17:51Z, #623 comment 6860746931):**
- The identity file is child-writable in W1. The service reads one immutable identity snapshot, never rules, API base, allowlists or parent PIN from that file. API base comes only from the compiled production constant or an explicit Debug environment override; the file cannot disable proxy enforcement. Tasks 1 and 5 each include a test row. A SYSTEM-only location and ACLs are W3 scope and, like W1b, block any outsider build.
- `TrayProtocol.MaxFrameBytes` is **65,536** and `TrayProtocol.ReadTimeout` is **15 seconds**. Task 3 tests 65,537 bytes before allocation and the exact timeout.
- Claude's device row covers Standard/admin `child_account_admin` and a second interactive session failing to open the first session's pipe, using the unsigned CI artifact on the isolated Windows Server 2025 machine.

## Review Focus

- A pause/routine/blocklist rule must not terminate the supervised tray: Task 4 tests every kill route with a protected tray PID/path.
- A client-supplied SID/session or executable path must not grant pipe access or choose a process to launch: Tasks 2 and 3 test the OS-derived identity and fixed co-located path.
- A valid stored identity plus hostile Release environment values must still use only the stored identity and compiled API, including the direct HMAC fallback in `ApiClient`: Task 1 tests every variable and the fallback.
- Session 0 must not open a window, lock a workstation, beep or register a hotkey: Tasks 2 and 4 inspect host registrations and fake all interactive actions.
- A tray must not inject parent-only commands, oversized frames or a capabilities report for SYSTEM: Tasks 3–5 test direction, bounds and identity.
- Pairing while the unpaired service is already running must start enforcement without a manual service restart: Task 5 tests the credential-free pairing-complete signal.

---

### Task 1: Release configuration and truthful client identity

**Files:**
- Modify: `apps/agent-desktop/FamilyShield.Agent.csproj`
- Modify: `apps/agent-desktop/Services/AgentConfig.cs`
- Modify: `apps/agent-desktop/Services/ApiClient.cs`
- Create: `apps/agent-desktop/Services/DesktopClientIdentity.cs`
- Modify: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/AgentConfigTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/DesktopClientIdentityTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/ApiClientHeaderTests.cs`

**Interfaces:**
- Produces: `AgentConfig.Load(string exeDir, bool allowEnvironmentOverrides)`, `[JsonIgnore] AgentConfig.AllowEnvironmentOverrides { get; private set; }`, `AgentConfig.ProductionApiBase`, `DesktopClientIdentity.Header`, and `DesktopClientIdentity.CapabilityClient()`. `AllowEnvironmentOverrides` defaults to `false`; `Load` records the explicit host choice, and `ApiClient` consults it before using its legacy HMAC environment fallback.
- Debug hosts pass `allowEnvironmentOverrides: true`; Release hosts pass `false`. Tests call the flag explicitly rather than depending on the test project's own configuration.
- The shared project supplies version `0.1.0`, build `1`; `Header` is `agent-desktop/0.1.0+1 (windows)`. Invalid version/build input omits the header/report rather than guessing.

- [ ] **Step 1: Write failing tests.** Parameterize `EnvVarsOverrideFileValues`, env-only identity, PIN adoption and proxy override over `allowEnvironmentOverrides`. In Release, every hostile value is ignored and the stored values survive. Assert `ApiClient` does not use its direct `INTERNAL_HMAC_SECRET` fallback in Release and that every request (not only POST) carries the exact header. Assert no header for a malformed version/build.
- [ ] **Step 2: Run the focused tests and confirm RED.**

Run: `dotnet test tests/FamilyShield.Agent.Tests --nologo --filter 'FullyQualifiedName~AgentConfigTests|FullyQualifiedName~DesktopClientIdentityTests|FullyQualifiedName~ApiClientHeaderTests'`
Expected: missing `DesktopClientIdentity`, the new `Load` flag and failed Release isolation assertions.
- [ ] **Step 3: Implement the explicit configuration boundary.** Keep Debug compatibility. In Release use the compiled production URL, never the listed environment variables, and remove the direct environment HMAC fallback. Do not print, persist or transmit the test values. Use the existing assembly metadata for version/build and reject values that cannot satisfy the server's header grammar.
- [ ] **Step 4: Re-run the focused tests in both configurations.** Expected: all selected cases PASS in Debug and Release.
- [ ] **Step 5: Commit** `test: pin release configuration and client identity (#623)` then `feat: isolate release configuration (#623)`.

### Task 2: Shared library, two hosts and session supervision

**Files:**
- Modify: `apps/agent-desktop/FamilyShield.Agent.csproj`
- Create: `apps/agent-desktop/src/OSRA.Service/OSRA.Service.csproj`
- Create: `apps/agent-desktop/src/OSRA.Service/Program.cs`
- Create: `apps/agent-desktop/src/OSRA.Service/TraySupervisor.cs`
- Create: `apps/agent-desktop/src/OSRA.Service/SessionProcess.cs`
- Create: `apps/agent-desktop/src/OSRA/OSRA.csproj`
- Create: `apps/agent-desktop/src/OSRA/Program.cs`
- Modify: `apps/agent-desktop/Program.cs` (move shared runtime composition into the library, not another executable)
- Modify: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/FamilyShield.Agent.Tests.csproj`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/TraySupervisorTests.cs`

**Interfaces:**
- Produces: `TraySupervisor.DesiredSessions(IEnumerable<InteractiveSession>)`, `TraySupervisor.Synchronize(...)` and `SessionProcess.StartInstalledTray(InteractiveSession)`.
- `InteractiveSession` carries OS-derived `SessionId`, user SID and state. `SessionProcess.StartInstalledTray` starts only `Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "OSRA.exe"))` through an isolated native-process adapter.
- Service registration includes supervisor, rule sync, process monitor and telemetry; interactive services are absent. Tray registration owns pairing, overlays, workstation lock, ring, SOS and foreground sampling.

- [ ] **Step 1: Write failing host/supervisor tests.** Cover session 0 and disconnected sessions skipped; every active interactive session selected once; only an actual missing/exited tray restarted; unknown paths rejected; quoted fixed path and `winsta0\default` passed to the native adapter; service descriptors exclude `LockOverlay`, `LockWorkStation`, `SosHotkey` and pairing UI.
- [ ] **Step 2: Run `dotnet test ... --filter FullyQualifiedName~TraySupervisorTests`; confirm RED on missing host/seam types.**
- [ ] **Step 3: Convert the current project to a shared library and add the two hosts.** Reference the library from both hosts and tests; expose host internals only to the existing test assembly. Add `Microsoft.Extensions.Hosting.WindowsServices` 8.0.0 to the service and `UseWindowsService`, with content root/config directory explicitly `AppContext.BaseDirectory`. The tray is a WinExe, `OSRA.exe`. Use `WTSQueryUserToken`/`CreateProcessAsUser` behind `SessionProcess`; no `ShellExecute`, user-supplied command line or unquoted executable path.
- [ ] **Step 4: Run the focused tests and `dotnet build` both hosts in Debug and Release.** Expected: selected tests and all four builds PASS. No host is launched.
- [ ] **Step 5: Commit** `test: specify service and session supervision (#623)` then `feat: add service and tray hosts (#623)`.

### Task 3: Per-session, identity-checked typed pipe

**Files:**
- Create: `apps/agent-desktop/Services/TrayProtocol.cs`
- Create: `apps/agent-desktop/Services/TrayPipeServer.cs`
- Create: `apps/agent-desktop/Services/TrayPipeClient.cs`
- Create: `apps/agent-desktop/Services/TrayClientIdentity.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/TrayProtocolTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/TrayPipeSecurityTests.cs`

**Interfaces:**
- Produces: `TrayPipeName.ForSession(int sessionId)`, `TrayProtocol.ReadAsync`/`WriteAsync`, `TrayClientIdentity.Verify(clientPid, expectedSessionId, expectedSid)`, and an injected `ITrayServer`/`ITrayClient` boundary for host tests.
- Server-to-tray kinds: `rules`, `lock`, `unlock`, `pause`, `resume`, `ring`, `wind_down`, `pairing_reset`. Tray-to-server kinds: `hello`, `pairing_complete`, `foreground_sample`, `sos`, `capabilities`. Strict JSON rejects unknown fields/kinds and unknown directions. Frames are length-prefixed and capped at 64 KiB before allocation.

- [ ] **Step 1: Write failing protocol and ACL tests.** Assert SYSTEM plus the specified SID only, no Everyone/Authenticated Users, local pipe names containing only the validated integer session, same-user/same-session acceptance, and rejection of a wrong SID, wrong session, spoofed hello SID, parent-command direction, malformed JSON, unknown fields, truncated frames and oversized frames.
- [ ] **Step 2: Run the two new test classes; confirm RED on the missing protocol/security types.**
- [ ] **Step 3: Implement the pipe with the .NET 8 shared-framework `System.IO.Pipes.AccessControl` APIs (no legacy package; Claude's ruling in #623 comment 6867483961).** Do not use `CurrentUserOnly`, which would exclude SYSTEM. Verify the actual client PID/token and session server-side; hello is never proof of identity. Enforce read timeouts/cancellation, one reader and writer per stream, bounded frames and no raw secret-bearing `AgentConfig` serialization. Use an injected native identity accessor in tests.
- [ ] **Step 4: Run protocol/security tests plus a loopback same-user integration test.** Expected: all PASS, rejected cases have no side effects, and no real service/UI action occurs.
- [ ] **Step 5: Commit** `test: prove per-session pipe boundaries (#623)` then `feat: secure the tray pipe (#623)`.

### Task 4: Preserve enforcement in the correct process

**Files:**
- Modify: `apps/agent-desktop/Services/RuleSyncService.cs`
- Modify: `apps/agent-desktop/Services/ProcessMonitor.cs`
- Modify: `apps/agent-desktop/Services/ScreenTimeEnforcer.cs`
- Modify: `apps/agent-desktop/Services/SosHotkey.cs`
- Create: `apps/agent-desktop/Services/ForegroundActivityAccumulator.cs`
- Create: `apps/agent-desktop/Services/TrayCommandRouter.cs`
- Modify: `apps/agent-desktop/src/OSRA.Service/Program.cs`
- Modify: `apps/agent-desktop/src/OSRA/Program.cs`
- Modify: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/RuleSyncDispatchTests.cs`
- Modify: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/ProcessMonitorPauseTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/TrayCommandRouterTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/ForegroundActivityAccumulatorTests.cs`

**Interfaces:**
- `TrayCommandRouter.Route(DeviceCommandDto)` returns typed service-local actions and tray commands; tray UI resolves PIN locally.
- `ProcessMonitor` receives a protected-process predicate. The supervisor protects its own PID and every live installed-tray PID/path before any kill route.
- The tray reports only the foreground process name at five-second samples. `ForegroundActivityAccumulator` retains the existing whole-minute accounting and idle/`LockApp`/`LogonUI` exclusions; session 0 never reads a user's foreground window.

- [ ] **Step 1: Move/add failing tests.** Lock/pause/resume/wind-down/ring reach only a fake tray sink with no PIN in any message; `bonus_time`, rules and internet pause retain their local semantics; the tray's fake overlay/workstation/ring/SOS sinks execute in its own host. Prove the supervised tray survives pause, routine allowlist, explicit app block and blocklist enforcement. Prove idle samples do not accumulate and valid samples upload through the service store.
- [ ] **Step 2: Run the modified/new tests; confirm RED on service-side UI calls, missing protected-process injection and missing activity path.**
- [ ] **Step 3: Implement routing and host wiring.** Remove service-side direct overlay/workstation/ring/SOS registration. Keep rule sync/process killing/telemetry in the service and pairing/UI/screen-time/SOS/foreground sampling in the tray. Tray PIN verification stays local. SOS becomes a typed pipe event posted by the service; Release enables the hotkey without an environment opt-in. Preserve existing warning/allowlist behavior and do not start real UI or audio in tests.
- [ ] **Step 4: Run all desktop tests in both configurations.** Expected: baseline plus new cases PASS, no regressions in existing rule/screen-time/pause suites.
- [ ] **Step 5: Commit** `test: pin session-correct enforcement (#623)` then `feat: route enforcement between service and tray (#623)`.

### Task 5: Server-free pairing and capability reporting

**Files:**
- Modify: `apps/agent-desktop/Services/PairingDialog.cs`
- Modify: `apps/agent-desktop/Services/PairingService.cs`
- Modify: `apps/agent-desktop/Services/Dtos.cs`
- Modify: `apps/agent-desktop/Services/ApiClient.cs`
- Create: `apps/agent-desktop/Services/DesktopCapabilities.cs`
- Modify: `apps/agent-desktop/src/OSRA.Service/Program.cs`
- Modify: `apps/agent-desktop/src/OSRA/Program.cs`
- Modify: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/PairingServiceTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/DesktopCapabilitiesTests.cs`
- Create: `apps/agent-desktop/tests/FamilyShield.Agent.Tests/RuntimeCoordinatorTests.cs`
- Modify: `packages/shared-types/src/capabilities.ts`
- Modify: `services/api/test/capabilities.test.ts`
- Modify: `services/api/test/capabilities-groups.test.ts` (fixture only)

**Interfaces:**
- `IAccountIdentity` exposes the OS-derived SID and administrator verdict. `DesktopCapabilities.Create(IAccountIdentity user, RuntimeFacts facts)` returns the strict client/grants/features object; `WindowsAccountIdentity` is the production adapter. No PIN, token, HMAC or server field is present.
- Pairing claim and every poll carry the client header; claim carries capabilities. `TelemetryBatchDto.Capabilities` serializes as `capabilities`; the service attaches the most recent tray report and omits it when no report exists.
- `pairing_complete` carries no credentials. The service notices the newly saved co-located config, builds the authenticated runtime and starts it without a manual restart.

- [ ] **Step 1: Write failing tests.** The pairing form has code plus two PIN fields and no server control. Assert the claim body/header, both admin states, only supported desktop feature keys, no invented `not_supported`, no device secrets in the report, and telemetry inclusion/omission. Assert an unpaired service starts no network runtime, while the pairing-complete signal starts it once with the saved identity. Add shared-types/API acceptance of `child_account_admin` and rejection of unknown grant keys remains intact.
- [ ] **Step 2: Run the focused desktop tests and API capabilities tests; confirm RED before implementation.**
- [ ] **Step 3: Implement pairing, report composition and runtime reload.** Use `WindowsIdentity.GetCurrent()`/`WindowsPrincipal.IsInRole(WindowsBuiltInRole.Administrator)` only at the tray boundary, with an injectable identity for tests. Preserve current supported-feature honesty; do not claim W2/W3/W4 capabilities. Pairing persists beside the tray/service executables and signals completion without transmitting the PIN.
- [ ] **Step 4: Run all desktop and API suites.** Expected: all tests PASS, including existing schema, pairing and capability rows.
- [ ] **Step 5: Commit** `test: cover desktop pairing and capabilities (#623)` then `feat: report desktop identity and capabilities (#623)`.

### Task 6: Unsigned CI artifact, documentation and full verification

**Files:**
- Modify: `.github/workflows/agent-desktop.yml`
- Modify: `docs/TESTING.md`
- Modify: `docs/README.md` (index this implementation plan)
- Modify: `docs/ROADMAP.md`
- Create: `CHANGELOG.d/2026-11-13-windows-w1-service-tray.md`

**Interfaces:**
- CI tests Debug and Release, publishes both hosts and their shared dependencies co-located in one self-contained `win-x64` artifact named `OSRA.Windows-W1-unsigned`, and performs no install/signing/AWS/store operation.

- [ ] **Step 1: Extend the workflow with test/publish steps.** Use the existing checkout/.NET actions, `dotnet test -c Debug`, `dotnet test -c Release`, publish `src/OSRA.Service` and `src/OSRA` to the same runtime directory, then `actions/upload-artifact@v4`. ARM64 and MSI belong to W3.
- [ ] **Step 2: Update the testing guide, roadmap 5.4 and changelog.** Include exact test/publish commands, no-device limits, unsigned-artifact status, W1b/W2/W3/W4 exclusions, and no claim of clean-machine verification. Preserve every other roadmap row when merging `main`.
- [ ] **Step 3: Run the complete local gate.**

```bash
dotnet test tests/FamilyShield.Agent.Tests -c Debug --nologo
dotnet test tests/FamilyShield.Agent.Tests -c Release --nologo
pnpm --filter @familyshield/shared-types test
pnpm --filter @familyshield/api test
node scripts/check-workflows.mjs --strict
node scripts/check-ci-paths.mjs --selftest
node scripts/check-ci-paths.mjs
node scripts/check-no-pins.mjs
node scripts/check-docs-links.mjs
git diff --check
```

Expected: all exit 0. Read the .NET test totals, publish both hosts successfully, inspect the co-located artifact, and report exact counts rather than estimates.
- [ ] **Step 4: Inspect the delivered diff.** No Arabic edits, new plaintext PIN path, secrets, generated binaries or unrelated proxy/DNS/MSI/updater work. Remove local artifacts from tracking; leave the working tree clean after committing intended files.
- [ ] **Step 5: Open the #623 PR with the approved restatement, raw test results, package additions and explicit unverified Windows-machine claims.** Enable auto-merge and notify Claude that the unsigned CI artifact is ready for the isolated Windows Server 2025 run. Do not merge directly.

---

## Approved R3 scope expansion (#754 comment 6869067412)

Claude ruled that all five areas in osra-security#22 belong in W1. Only service-side foreground sampling moves to W2. The following known limits are accepted and must remain explicit: same-user code injection into a user-mode tray; the existing plaintext PIN until W1b; the child-writable identity file, installed-directory ACLs and signing until W3; and self-reported foreground usage until W2. No clean-machine claim follows from these unit tests. Every native effect is behind an injected seam; never lock or disconnect this development session or contact a real family.

### Task 7: Bind both pipe endpoints and derive identity from tokens

**Files:** `InteractiveSession.cs`, `TrayClientIdentity.cs`, `TrayPipeServer.cs`, `TrayPipeClient.cs`, `TrayServerWorker.cs`, `ServiceIdentityVerifier.cs` (new), `SessionProcess.cs`, `TraySupervisor.cs`, `ServiceHostComposition.cs`, `DesktopRuntime.cs`, and endpoint/security test files.

**Interfaces:**
- `ITrayProcess.ProcessId` and an `ITrayProcessRegistry`, implemented by `TraySupervisor`, supply the actual process the service launched for each session. `NativeTrayProcess` retains the PID returned by `CreateProcessAsUser`.
- `ITrayServerFactory.Create(sessionId, userSid, expectedPid)` passes the launched PID to the server. A missing launched PID does not create an unauthenticated listener.
- `ClientIdentity` includes an optional image path for its test/native boundary. `TrayClientIdentity.Verify` can require an exact launched PID and normalized co-located image path in addition to session and SID. `WindowsClientIdentitySource` supplies the actual executable path.
- `IServiceIdentityVerifier` verifies the server PID's token user is `S-1-5-18` before the client sends `hello`. A test verifier can accept the loopback server without weakening production.
- `WtsInteractiveSessionSource` obtains the session user's SID through `WTSQueryUserToken` and the token user. No `NTAccount` translation remains. An injected session/account source proves that a name resolving to another SID cannot alter the ACL.

- [ ] **Step 1: Write failing tests.** Wrong PID, wrong image, non-SYSTEM server and network SID are refused; a correct launched tray connects after an impostor; the launched PID reaches the factory; token-derived SID alone determines the ACL; the ACL explicitly denies `S-1-5-2` (`NETWORK`).
- [ ] **Step 2: Run the focused tests and confirm RED on the missing PID/token boundaries.**
- [ ] **Step 3: Implement PID/image/server-token validation and token-derived session identity.** Preserve strict SID/session checks and all existing frame bounds. An impostor is refused before `hello` or any queued message is written. Replace a failed session with its queued messages preserved.
- [ ] **Step 4: Run the endpoint and whole desktop suites in both configurations.** No native process or real pipe is started by the new tests except the existing same-user loopback, which uses an injected server-token verdict.
- [ ] **Step 5: Commit** `test: pin both pipe endpoint identities (#623)` then `feat: bind the tray and service endpoints (#623)`.

### Task 8: Persist restrictions and protect an offline session

**Files:** `DesktopRestrictionState.cs` (new), `SessionFallback.cs` (new), `TrayServerWorker.cs`, `TrayCommandRouter.cs`, `ServiceHostComposition.cs`, `DesktopRuntime.cs`, `DesktopRestrictionStateTests.cs` (new), `TrayServerWorkerTests.cs`.

**Interfaces:**
- `DesktopRestrictionState` tracks locked, paused, wind-down deadline, last verified connection, disconnect time and one fallback per episode per session. It replays the current state before older queued messages on every accepted connection.
- `IDesktopSessionFallback.LockWorkstation(sessionId)` uses an injected native WTS disconnect seam in production and a recording fake in tests. The old empty `LockWorkstationAction` is removed, not hidden behind a no-op.
- A restricted session with no verified connection for 20 seconds gets one fallback and one tamper alert. Reconnection resets the episode. A failed pipe create is reported as tamper and follows the same fallback path; no real session is disconnected in tests.

- [ ] **Step 1: Write failing tests.** A new tray's first message is the current lock; pause and wind-down also replay; unlock/resume clear the appropriate state; an offline restricted session reaches the WTS fallback exactly once with one alert; reconnection resets the next episode; pipe-create failure produces the tamper path. No command is delivered to an unverified endpoint.
- [ ] **Step 2: Run the restriction tests and confirm RED on missing state and fallback seams.**
- [ ] **Step 3: Implement restriction state, full replay and WTS fallback.** State transitions match the existing tray behavior. Full current state precedes queued commands. Timer and clock are injectable.
- [ ] **Step 4: Run all desktop suites in both configurations, including pending-command retention.**
- [ ] **Step 5: Commit** `test: specify persistent restrictions and offline fallback (#623)` then `feat: keep restricted sessions protected (#623)`.

### Task 9: Bound SOS and identify tray-sourced reports

**Files:** `TrayServerWorker.cs`, `DesktopCapabilities.cs`, `packages/shared-types/src/capabilities.ts`, `services/api/src/lib/capabilities.ts`, `TrayServerWorkerTests.cs`, `DesktopCapabilitiesTests.cs`, `services/api/test/capabilities.test.ts`.

**Interfaces:**
- A per-device clock permits at most one SOS POST per 60 seconds; a repeated event inside the window is logged and not sent.
- `source: "tray"` is added to desktop capability reports and accepted by the strict shared/API schema. Other sources and unknown top-level fields remain rejected; existing Android/iOS reports without `source` remain valid. `DesktopCapabilitiesStore` requires exactly this source and rejects missing/other sources.

- [ ] **Step 1: Write failing tests.** First SOS posts, second at 59 seconds does not, third at 60 seconds posts. Desktop report/store asserts `source: tray`; the API accepts that exact source and rejects another. Existing non-desktop reports remain accepted.
- [ ] **Step 2: Run the focused .NET and API tests and confirm RED.**
- [ ] **Step 3: Implement the SOS window and source field.** Do not derive trust from a client-supplied SID. Foreground usage is explicitly self-reported until W2, not silently promoted to a service measurement.
- [ ] **Step 4: Run all desktop suites in both configurations and the full API suite.**
- [ ] **Step 5: Commit** `test: pin SOS throttling and report provenance (#623)` then `feat: bound tray-originated reports (#623)`.

### Task 10: Record the security scope and refresh the artifact

**Files:** `docs/adr/0041-one-family-plan-and-computer-downloads.md`, `docs/TESTING.md`, `docs/ROADMAP.md`, `README.md`, `CHANGELOG.d/2026-11-13-windows-w1-service-tray.md`, this plan, `.github/workflows/agent-desktop.yml` only if a gate changes.

- [ ] **Step 1: Amend ADR-0041 D6's W1 scope with the five areas and the accepted known limits.** Document exact counts, no-device limits and self-reported foreground usage. Do not claim W1b, W2, W3 or W4 is complete.
- [ ] **Step 2: Run every desktop configuration, the full API and repository guards.** Publish and inspect the refreshed unsigned win-x64 artifact without executing it; clean local outputs afterward.
- [ ] **Step 3: Review the complete R3 diff, fold current main and rerun affected checks.** No secrets, Arabic edits, new plaintext PIN path or unapproved W2/W3/W4 work.
- [ ] **Step 4: Update PR #754 with raw results, known limits and security questions resolved.** Keep WIP until Ahmed's dependency disposition. Then mark ready, enable auto-merge, and ask Claude for the isolated Windows Server 2025 rows and Fable for the R3 key. Never merge directly.

### Task 11: Close the device-level and durability gaps (Fable W6–W9)

**Interfaces and acceptance:**
- Observe restrictions at device level, not only in existing slots. A session that appears later receives the current lock/pause/wind-down and is eligible for fallback even if no PID, pipe or slot ever existed.
- Persist restriction state in a service-owned, SYSTEM/admin-only JSON store. Missing state starts empty; corrupt state is not silently forgotten. The store atomically replaces its file and tests its ACL and round trip. Runtime connection flags are not restored as trusted connections.
- Re-arm the fallback every 20-second grace period while a restriction remains without a verified tray, including after a service restart. A verified reconnect resets the episode and alert throttle.
- Verify the server through `GetNamedPipeServerSessionId` on the pipe, requiring session 0, with no attempt to open a SYSTEM process or token. A separate CI-only Windows SYSTEM service probe exercises the production pipe server and client, never the developer's real service, desktop, installer or production.
- Protect the supervisor PID registry with a lock. A full outgoing queue must not remove an unsent message after a successful older write. Tray SOS feedback remains local and does not promise server delivery.

- [ ] **Step 1: Write failing tests.** Device-level observation without a slot, persisted state and ACL, repeated fallback after 20 seconds, server-session verification, and full-queue preservation. The CI service probe is built locally but never launched locally.
- [ ] **Step 2: Run the focused tests and confirm RED on the missing store, device observation and session-ID boundary.**
- [ ] **Step 3: Implement device-level persistence, re-armed fallback, session-0 verification and the thread/queue fixes.** Production uses the service-owned store; tests use only temp files and fakes. Do not add a plaintext PIN or credential to the persisted state.
- [ ] **Step 4: Run all desktop configurations and compile the service probe, then run the real CI-only service row on the next head.** No local Windows service is created, stopped or deleted.
- [ ] **Step 5: Commit** `test: pin durable device restrictions (#623)` then `feat: persist and verify restricted sessions (#623)`.

### Task 12: Protect the state directory and recover fail-closed (Fable W10–W12)

- A service-created directory has a SYSTEM owner or Administrators owner, is not a reparse point, and grants no other principal write access. Every load/save rechecks it. A temporary file is created protected with `FileMode.CreateNew`; no untrusted pre-existing file is overwritten.
- A missing restriction file means no stored restriction. An unreadable/corrupt/insecure state means `Unreadable = true`, a locked replay and an immediate fallback/alert, not a startup crash and not a free device. Loading corrupt state leaves its bytes untouched until explicit fallback recovery writes known-good locked state; no separate audit quarantine is claimed.
- After the directory trust check, a stale temporary file is removed before the protected `CreateNew`. A failed save retains in-memory enforcement and produces one error log and one tamper alert per continuous failure episode, resetting only after a successful save.
- `unlock` and `resume` clear all session and device restrictions, including a session the fallback disconnected. A later sign-in cannot inherit an unlocked restriction.
- [x] Write failing tests for insecure directories, ACLs, missing/corrupt state and disconnected-session unlock. Run them RED, implement minimally, then run the complete desktop suite and the real CI probe again.
- [x] Update ADR-0041, the testing guide and the PR with the actual real-service result. Keep the artifact unsigned and keep W1b/W2/W3/W4 exclusions explicit.

### Task 13: Close the remaining review evidence gaps (Fable p8, t1–t4 and process-lane stability)

- A valid first frame other than `hello` is rejected and the connection closes, rather than hanging until the outer test timeout.
- The process-protection test uses a cross-process gate so two verification lanes cannot terminate each other's disposable child while their pause/blocklist sweeps overlap.
- The real SYSTEM probe covers both ordinary stale-temp recovery and a competing temp file created after stale cleanup. Production still creates the new file protected with `FileMode.CreateNew`; `Create` must fail the collision row.
- [x] Add the first-frame row, process gate and post-cleanup collision seam; run both desktop configurations and compile the real probe.
- [x] On `verify/754-*` branches, plant each of t1 (owner), t2 (reparse), t3 (other writer) and t4 (`CreateNew` to `Create`) separately and link four red CI runs. Keep those branches out of the product PR and do not merge them.
- [x] Re-run the exact product head with all cleanup markers, update the PR/ledger and request independent R3 verification. Never claim readiness from the author's green runs alone.

### Task 14: Repair the composed hosts and pipe lifetime

- Resolve each concrete pipe worker once from the real service/tray container, share it with `ITrayCommandSink`, and resolve the pairing coordinator after all transport registrations. The paired host and idempotent coordinator disposal are covered too.
- Replace the one-shot client drain with full-duplex operation and reconnection after disconnects. `TrayPipeClient.ConnectAsync` owns exactly one fresh `hello` on every connection; the worker must not duplicate it. Quiet established connections do not hit the first-frame 15-second timeout.
- Preserve SOS ahead of bounded ordinary traffic. Prove real composition, the production file-store registration and post-connect/quiet-connection behavior. Completed with 335/335 tests in both configurations.
- [x] Commit tests separately from implementation and run both full desktop configurations.

### Task 15: Acknowledge SOS delivery and retry failed posts

- Return strict `sos_result { accepted: boolean }` from the service. Set the per-device successful-SOS timestamp only after `PostAlert` returns true. A recent successful alert answers a repeated event without a second POST; a failure does not suppress an immediate retry.
- Keep one outstanding SOS, coalesce repeated presses, and retry failed/unacknowledged SOS without dropping it behind 32 ordinary messages. Serialize result replies through the one pipe writer.
- Show success only after the accepted service result. Show Claude's retry wording for a failed result, with feedback isolated behind a test seam; never open a real toast or hotkey locally. Request Bureau review for the changed visible copy.
- [x] Add fail-first service, protocol, client and feedback rows; run both configurations and request the wording review. Completed with 339/339 tests in both configurations; Bureau review remains a readiness gate.

### Task 16: Merge restrictions and make restart/pipe handling resilient

- Merge a stale session record with the current device restriction. After loading persisted state, start disconnected with a fresh grace period and no inherited connection/fallback alert episode. Explicit fallback recovery clears all recovered unreadable markers rather than reintroducing one through the merge.
- Reuse a live co-located tray for the same session before launching a duplicate; derive the process from the OS through an injected discovery boundary.
- Create pipes with `FirstPipeInstance`. Retain queued messages on create failure, continue other sessions, and always delay/back off after exceptions. Isolate session enumeration/token failures per session in both supervisor and fallback passes. Save-failure alerts are high, or critical when unreadable state survived restart, with the Bureau-approved title.
- [x] Add fail-first stale-record, restored-grace, discovery, create-failure, other-session and timing rows; run both configurations. Completed with 350/350 tests in both configurations.

### Task 17: Correct capability/API boundaries and parent CI coverage

- Warn only for an administrator child, not for the safe Standard setup; report configured-but-not-yet-connected interactive features as `degraded`, never pairing-time `unavailable` solely because the pipe has not completed `hello`.
- Accept `source: tray` and `child_account_admin` only for `agent-desktop`; retain existing reports for other platforms.
- Keep the desktop-only grant out of the generic 13-grant parent fix list unless Claude specifies a separate approved warning projection. Do not add Arabic copy. Add `packages/shared-types/**` to parent workflow triggers and update its outside-input test.
- [x] Run focused .NET/API tests RED, implement, then run full desktop/API/shared-types/parent and repository gates. Completed with 351/351 desktop tests in both configurations, API 911 passed/3 environment-gated skips, parent 637/637, clean analysis and shared-types build.

### Task 18: Exercise the real pipe security and production composition

- F1: drive identity refusal through `AcceptAsync`, then accept the genuine launched tray; deleting the identity verification must turn the test red.
- F2: inspect the ACL of the actual created pipe and exercise a real same-user/session connection; replacing the session ACL with null must fail.
- F3: resolve `FileDesktopRestrictionStore` from the real production registration, with an isolated path supplied through the test composition rather than replacing it with an in-memory fake.
- [x] Run a real-worker loopback covering post-hello lock delivery, 20 seconds of quiet lifetime and messages queued after connect; execute no real service, installer or UI action locally. The real-client handshake exposed and removed a duplicate worker `hello`; both real-session tests share a cross-process pipe-name semaphore. Both full configurations pass 354/354.

### Task 19: Re-verify and return #754 for independent R3 review

- [ ] Append exact implementation and test results to the ledger, plan, ADR-0041, testing guide, roadmap, README and changelog. Preserve historical claims and explicitly supersede stale evidence.
- [ ] Run both desktop configurations, API, shared-types build, parent suite, strict workflow lint, CI paths, no-PIN/service-account/docs-link guards, whitespace checks and the real CI-only SYSTEM probe. Confirm all three markers and cleanup on the exact new head; refresh the unsigned artifact.
- [ ] Review the whole branch without substituting K3/DeepSeek for the requested K3.1 Pro reviewer. Fold current main without rebase and repeat affected checks.
- [ ] Update the PR body and notify Claude immediately when each milestone completes. Restore readiness and auto-merge only after implementation, author gates and required Bureau review; obtain cross-family verification, Fable's R3 key and Ahmed's security/dependency disposition. Never merge directly.

### Task 20: Close the established-connection test gaps (Fable L3/L7)

- [x] Prove an ordinary foreground sample queued after `hello` reaches the service through the real client worker; planting `_pending.Peek()` to null turns it red and restoration turns it green.
- [x] Complete `hello` + SOS, then EOF before `sos_result`. The next connection sends `hello` and the same SOS again. Removing only the disconnect-time requeue turns this row red; restoration turns it green. The fake stream completes the write before EOF so the test exercises that specific requeue rather than a write-failure race.
- [x] Run the focused rows and both complete configurations, 356/356 each. No production code changed; this is test and documentation evidence only.
