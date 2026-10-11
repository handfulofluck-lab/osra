# ANTIGRAVITY INBOX — OSRA QA work queue (2026-10-11)

**Who this is for:** Antigravity (implementation agent). **Owner:** Kimi Code (QA/verification).
**Working agreement:** `AGENTS.md` at the repo root — read it before starting.

## How to work an item

1. Pick the **highest-priority open item** (P0 first).
2. Fix it on a branch; add a test that fails before your fix.
3. Run the gates (`AGENTS.md` §3). The item's **Acceptance** line names the exact
   `qa-probe` checks that must flip from FAIL to PASS — nothing else may regress.
4. In the PR: item ID, what you changed, gate output, and anything you deliberately left.
5. Kimi re-runs the gates and verifies the specific claim; the item moves to *Verified* or comes
   back with evidence.

> **Rule:** never weaken a check to make it pass. If a check is wrong, say so with evidence.

## Current gate status (2026-10-11)

| Gate | Result |
|---|---|
| `services/api` vitest | 192/193 — the one failure is `auth.test.ts` login timing out at 20 s **under heavy machine load**, not an assertion failure; passes on an idle run. Worth a `testTimeout` bump, not a product fix. |
| `services/api` live e2e | **50/50** |
| `services/api` qa-probe (adversarial) | **49 passed · 19 failed · 2 targets · 2 notes** ← the fix list below |
| Flutter parent-app | 94/94 |
| Android JVM | 151/151 |
| Desktop xunit | 168/168 |
| AI engine | 18 passed / 1 skipped |

Reproduce the probe (needs a live stack):
```bash
cd services/api
INTERNAL_HMAC_SECRET=<from dist/start-backend.bat> node scripts/qa-probe.mjs
```

---

# P0 — safety-critical (do these first)

## P0-1 · API-02 · high · per-device signing secrets leak to parents *and* to any device JWT
**Probe checks:** `F5`, `F6`, `F7`, `G3`, `G4`, `G5`, `G6b`
**Evidence (verified live):** `GET /v1/family/me`, `GET /v1/family/export`, `GET /v1/devices`,
and `GET /v1/devices/:id` all return the device row's `internalSecret` — the per-device HMAC key
that authenticates agent→server alerts. A **device JWT** also gets `200` on `/v1/devices` and on a
*sibling* device, i.e. a child device can harvest every sibling's key.
**Root cause:** the parent-facing device payloads strip only `pushToken`
(`services/api/src/routes/family.ts:53,186`); `internalSecret` was added later and is passed through
by omission. `/v1/devices` list + detail use role-agnostic guards
(`devices.ts:163`, `devices.ts:176`).
**Impact:** any parent-side reader, GDPR export file, or backup contains the key that proves a safety
alert is genuine; any device can forge alerts as a sibling (see P0-4).
**Acceptance:** the seven checks above pass; a test asserts no secret-ish key appears in any
parent or device payload.
**Suggested fix:** Prisma `select` allowlist for client payloads (never select `internalSecret` /
`pushToken`); make `/v1/devices` list + detail `requireParent`; let a device read only its own row.

## P0-2 · IOS-01 · critical · every iOS alert is rejected (401)
**Probe checks:** `J4`
**Evidence (verified live):** a body signed with the device's **own** secret but **without** a
top-level `deviceId` → `401`; the same body **with** `deviceId` → `201`; no `deviceId` + the global
secret → `201`. `internalAuth.ts:20-30` looks up the per-device secret only when the body carries
`deviceId`, otherwise it falls back to the global `INTERNAL_HMAC_SECRET`. The iOS `AlertReporter`
payload has no `deviceId` (`apps/child-ios/Sources/FamilyShieldAgent/DeviceActivityMonitor.swift:43-59`).
**Impact:** the entire iOS alert pipeline is inert — tamper, SOS and social concerns never reach a parent.
**Acceptance:** `J4` passes — a request signed with the device's own secret is accepted **without the
client echoing its own id**.
**Suggested fix (server-side preferred):** bind the secret lookup to the authenticated device
(e.g. accept an `x-device-id` header, or resolve from the token) instead of keying off the request
body. Server-side is preferred because it also unblocks already-written iOS builds — no Mac rebuild
needed. Keep the global secret for the ai-engine only. Add a round-trip test per client payload shape.

## P0-3 · AND-01 · critical · tamper / VPN / install / unknown-contact alerts are silently dropped
**Probe checks:** section `I` — the four failing categories
**Evidence (verified live):** `POST /v1/alerts/internal` returns `400` for `tamper`,
`vpn_detected`, `install_request`, `unknown_contact`; the 9 enum categories return `201`. The agents
send the rejected four (`AccessibilityOffReceiver.kt:38`, `LocationService.kt:266`,
`PackageAddedReceiver.kt:66`, `CommsLogger.kt:230`), and
`packages/shared-types/src/world-class.ts` already defines them.
**Impact:** the parent never learns the child disabled accessibility (tamper), connected a VPN,
installed an app, or messaged an unknown contact — four headline features are inert.
**Acceptance:** every category in probe section `I` is accepted; a test covers each sender's category.
**Suggested fix:** extend the server enum to match `shared-types` (and check the Windows/macOS
senders' categories too), or map agent categories server-side.

## P0-4 · API-01 · high · a device can inject alerts and location pings into a sibling child
**Probe checks:** `G7`
**Evidence (verified live):** signed with device A's own secret but `childId` = sibling child B →
`201`, and the alert lands on **B**'s feed. The HMAC path never compares the body's `childId` with
the signing device's family (`alerts.ts:87-101`, `location.ts:45-55,110-120`, `social.ts:90-99`),
while the JWT path does check it (`location.ts:113`).
**Impact:** one child device can write into another child's safety history — poisoning reports,
alerts and geofence state.
**Acceptance:** `G7` passes.
**Suggested fix:** have `verifyInternalSignature` return the device's `{deviceId, childId, familyId}`;
each route asserts the body `childId` belongs to that family (and equals the device's own child for
telemetry/ping).

## P0-5 · API-04 · high · device revocation only applies under `/v1/devices`
**Probe checks:** `G10`, `G11`, `G12`
**Evidence (verified live):** after unpair, the device JWT still gets `200` on `/v1/rules/:childId`
and can still mint a WS ticket; `/v1/location/ping` returns **500** (not 401) and leaks a raw Prisma
error. The revocation hook is registered inside the `deviceRoutes` plugin, so Fastify encapsulation
limits it to that prefix (`devices.ts:287-297`, mounted at `server.ts:55`). Live e2e's
"unpaired device is revoked" check only exercises the guarded route, hence green.
**Impact:** an unpaired/removed device keeps enforcing reads and reporting location; the 500 leaks
internals.
**Acceptance:** all three checks return 401.
**Suggested fix:** register the revocation check on the root app so it runs for every route, and make
revoked requests fail before touching the database.

---

# P1 — high

| ID | Platform | Title | Evidence | Acceptance |
|---|---|---|---|---|
| AND-02 | Android | Screen-time counters are in-memory only → reboot resets the day's limits | `data/RuleRepository.kt:41`, `data/UsageCounters.kt:5` | new unit test: counters rebuilt from persisted events after process start |
| AND-03 | Android | No cached rules → every app allowed (fail-open) | `data/RuleRepository.kt:65` (`cached ?: return ALLOW`) | appliance test: paired + no rules = non-exempt apps blocked |
| AND-04 | Android | Block overlay is dismissible ("Close"); 2 s debounce grants burst access | `enforcement/BlockActivity.kt:143`, `enforcement/AppBlocker.kt:39` | test/assertion that the overlay cannot be finished by the child path |
| AND-05 | Android | `lock`/`pause` fallback overlay has no back/home guard | `commands/LockActivity.kt:49`, `commands/CommandDispatcher.kt:86` | lock persists until `unlock` |
| WIN-01 | Windows | Lock overlay defeated by Alt+F4; second monitor stays usable | `Services/LockOverlay.cs:100-106`, `ScreenTimeEnforcer.cs:72` | xunit/UI test: overlay resists close and covers all screens |
| WIN-02 | Windows | Bedtime uses the child's own Windows lock (child knows the password) and is killable | `ScreenTimeEnforcer.cs:57-63` | bedtime requires the parent PIN; re-asserted while active |
| WIN-03 | Windows | Screen time double-counted (foreground + rule samplers) → limits hit at ~2× | `ProcessMonitor.cs:68,150-175,383-393` | xunit: one tick credited once; 30 min rule ≈ 30 min |
| WIN-04 | Windows | Idle/locked time burns the screen-time budget (overnight "idle" rows) | `ProcessMonitor.cs:379-393`, `LocalRuleStore.cs:55` | xunit: locked/idle ticks accrue nothing |
| WIN-05 | Windows | Rename/copy defeats app blocking (name-only matching) | `ProcessMonitor.cs:130,311` | xunit: match by path/hash |
| WIN-06 | Windows | Filter is WinINET-only; WinHTTP, per-app proxy and VPN bypass it | `WebFilterProxy.cs:242-252` | document + at minimum alert; see also the tester's original Chrome/Firefox report |
| FLT-01 | Flutter | Concurrent 401s race the refresh → whole session revoked / forced logout | `lib/api/client.dart:16-45` (+ `auth.ts:216-245`) | widget/unit test: N parallel 401s → one refresh, no logout |
| FLT-02 | Flutter | `screenTimeTodayMinutes` read by the UI, never sent by the API → progress always 0 | `lib/api/models.dart:81,100`, `dashboard_screen.dart:114,182` | API sends it (or UI derives it); widget test asserts non-zero |
| FLT-03 | Flutter | "Always allowed" apps are never saved (server schema drops the field) | `models.dart:360-368`, `rules.ts:54-64,105-124`, `schema.prisma:82` | round-trip test: saved list comes back |
| FLT-04 | Flutter | Router lacks `refreshListenable` → restored session stranded on login | `lib/app.dart:16-23`, `auth_provider.dart:177-184` | widget test: warm start with stored token lands on dashboard |
| FLT-05 | Flutter | Pending invites read the wrong envelope key (`items` vs `invites`) | `family_provider.dart:94-99`, `invites.ts:59-66` | widget test asserts the list renders |
| FLT-06 | Flutter | Location history parses `ts`, API returns `timestamp` → "today's route" empty | `world_class_provider.dart:68-75`, `location.ts:143-158` | parse test against the real payload |
| IOS-01 | iOS | see **P0-2** | | |
| IOS-02 | iOS | Shielding can never work: tokens synthesised from bundle IDs; no `FamilyActivityPicker`/selection persistence | `ScreenTimeController.swift:88-90,29-30`, `DeviceActivityMonitor.swift:116-128` | design note + picker/selection round-trip |
| IOS-03 | iOS | `shield.applicationCategories` / `webDomainCategories` type mismatch — **won't compile** | `ScreenTimeController.swift:42-44` | compiles on macOS |
| IOS-04 | iOS | `ShieldConfiguration.Label(text:color:)` passes `nil` to non-optional `color` — **won't compile** | `ShieldConfiguration.swift:32-36` | compiles on macOS |
| IOS-05 | iOS | Bedtime end wipes rule shields; overlapping routines clobber one store; blocked-lists are read but never written | `DeviceActivityMonitor.swift:114-129,145-156` | design + tests on a Mac |

---

# P2 / P3 — medium and low (full detail in the audit files)

| ID | Sev | Title | File(s) |
|---|---|---|---|
| API-03 | high* | Consent gate only enforced at child creation; `revokedAt`/`expiresAt` never read; no revoke endpoint | see TARGET J3 |
| API-05 | med | Invite accept keeps old-family access until the access token expires | `invites.ts:85-89`, `auth.ts:118,137` |
| API-06 | med | Refresh rotation not atomic (concurrent double-spend) — **not reproduced** in a live race test (got 200/401); keep as hardening | `auth.ts:221-245` |
| API-07 | med | Live 15-minute password-reset JWT printed to the server log | `auth.ts:187` (verified in source) |
| API-08 | low | TOTP replay guard is non-atomic (TOCTOU) | `auth.ts:43-47` |
| API-09 | low | WS ticket single-use is non-atomic | `realtime/gateway.ts:37-40` |
| API-10 | med | Unbounded `Int`-backed fields → 500 with raw Prisma error to the client | `rules.ts:16-28`, `controls.ts:10-16`, probe `J1` |
| API-11 | low | Vault key falls back to `sha256(JWT_SECRET)` when `VAULT_KEY` is unset | `lib/snippetVault.ts:7-10` |
| API-12 | low | Device JWT can mint a parent WS ticket and read family-wide events | `gateway.ts:17-26` (probe `G6b`) |
| AND-06 | med | `pauseInternet` is process-local → reboot re-enables the internet | `RuleRepository.kt:47`, `CommandDispatcher.kt:125` |
| AND-07 | med | Bonus minutes lost on reboot and never restored (DTO lacks the field) | `RuleRepository.kt:50`, `network/dto/RulesDtos.kt:7` |
| AND-08 | med | Global screen-time counts always-allowed apps and the launcher | `RuleEngine.kt:92`, `AccessibilityMonitorService.kt:20` |
| AND-09 | med | Social capture walks the node tree on the main thread and leaks nodes | `social/SocialCapture.kt:50` |
| AND-10 | med | Unbounded buffering / DB growth while offline | `services/LocationService.kt:148`, `telemetry/UsageReporter.kt:84` |
| AND-11 | med | Telemetry watermark race can drop a just-recorded usage event | `telemetry/UsageReporter.kt:80` |
| AND-12 | low | Device/child ids logged to logcat via `HttpLoggingInterceptor` | `di/NetworkModule.kt:44` |
| WIN-07 | med | `ProxyOverride` bypass entries are invisible to the tamper check | `WebFilterProxy.cs:242-252`, `TamperChecks.cs:40-62` |
| WIN-08 | med | Filter fails **open** on handler exceptions and before the first rule sync | `WebFilterProxy.cs:143-196`, `LocalRuleStore.cs:281-292` |
| WIN-09 | med | Routine allowlist ignores always-allowed apps and kills `explorer` every tick | `ProcessMonitor.cs:95-121`, `Dtos.cs:94` |
| WIN-10 | med | All enforcement trusts the local clock (child can move it) | `LocalRuleStore.cs:55`, `ScreenTimeEnforcer.cs:55-58`, `TimeWindows.cs:13-35` |
| WIN-11 | med | `agent.config.json` stores the device JWT + HMAC secret in plaintext next to the exe | `AgentConfig.cs:21-30,69-77` |
| WIN-12 | low | `url_log` never pruned — full browsing history grows forever on disk | `LocalRuleStore.cs:349-366` |
| FLT-07 | med | Refresh failure clears tokens but leaves `AuthState` authenticated | `client.dart:37-43`, `auth_provider.dart:127-137` |
| FLT-08 | med | Location/wellbeing providers never refresh after the first fetch | `family_provider.dart:75-82,160-170`, `world_class_provider.dart:23-27` |
| FLT-09 | low | `install_request` alert actions are unreachable dead code | `alerts_screen.dart:111-123` |
| FLT-10 | low | Rules editor can hit an overlap rejection with no escape hatch | `rules_editor_screen.dart:61-79`, `rules.ts:127-134` |
| IOS-06 | med | `scheduleBedtime` bypasses the tested `RoutineWindow` logic; no validation | `ScreenTimeController.swift:48-60`, `RoutineWindow.swift:31,48-56` |
| IOS-07 | med | Pairing request has no timeout — UI can hang on "Pairing…" | `PairingClient.swift:63-85`, `PairingView.swift:51-54,72` |
| IOS-08 | med | Alerts are fire-and-forget: no retry/queue; unpaired state drops silently | `DeviceActivityMonitor.swift:27-42,63-69` |
| IOS-09 | low | `AgentIdentityStore.save` silently no-ops without the app group; reports "Paired" | `AgentIdentityStore.swift:28-41`, `PairingView.swift:78` |
| MAC-01 | low | macOS scaffold writes a healthy-looking `status.json` while enforcing nothing | `apps/agent-macos/Services/PortableStatus.cs:34-42` |

`*` API-03 is rated *high* by the API audit but needs a product decision (see below).

---

# Targets — need a human decision (probe reports them, they do not gate)

- **J2 · agent request replay protection.** The agent signature covers only the JSON body — no method,
  path, timestamp or nonce — so a captured signed request can be replayed (verified: two identical
  signed alerts → two alerts). Decide: add `x-timestamp` + nonce and reject replays, and/or bind the
  signature to method+path.
- **J3 · consent revocation.** There is no revoke endpoint (`404`) and nothing reads
  `ConsentRecord.revokedAt`/`expiresAt`, so consent can be granted but never withdrawn — a COPPA/GDPR-K
  gap. Decide the semantics, then wire revocation into all child-scoped writes (428/403).
- **B11 · parent token can drain the device command queue** (`200`). The route is a destructive drain
  (`GET /v1/devices/:id/commands`); if a parent previews it, commands never reach the child. Decide:
  keep parent preview (non-destructive read) or restrict to devices.

---

# Verified solid — do not "fix" these

Each audit ends with a "Verified solid" section; read it before touching a subsystem. Headlines:

- **API:** parent-only mutations consistently reject non-parent roles; `requireFamily` scoping is
  correct for JWT routes; HMAC comparison is constant-time and fails closed; pairing-code claim is
  atomic and single-use; push tokens and `passwordHash`/`mfaSecret` are stripped from `/me` and
  `/export` (only `internalSecret` was missed — P0-1).
- **Android:** cold-start token reads, minutes clamping, rule-window math (ISO days, midnight wrap),
  location-flush mutex, pairing form contract.
- **Windows:** proxy save/restore + `reset-proxy.bat`, block-decision precedence, upload cursors,
  tamper throttling, config-corruption handling.
- **Flutter:** (see the audit's "Verified solid" section.)
