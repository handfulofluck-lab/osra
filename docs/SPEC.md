# FamilyShield — Master Specification (reference for implementation agents)

> **Branding convention (2026-09-18):** the product is branded **OSRA (أسرة)**. User-facing
> strings say OSRA; technical identifiers intentionally keep the `familyshield` namespace
> (Dart package `familyshield_parent`, Kotlin `com.familyshield.agent`, C# `FamilyShield.Agent`,
> SwiftPM `FamilyShieldAgent`, the `X-FamilyShield-Signature` header, `familyshield.dev` dev
> domain, DB name `familyshield`). Do not "fix" identifier names in code — new code must follow
> this split (OSRA in UI strings, familyshield in identifiers) and document it here.

This file is the ground-truth spec for the FamilyShield monorepo. Implement exactly what is
described here. Rules of engagement:

- Fill `// TODO: KIMI CODE` markers; generate files marked **GENERATE THIS**.
- Do not rewrite existing (DONE) files unless they are broken.
- Do not add new dependencies without updating the relevant manifest.
- Every public function gets a one-line docstring.
- If the spec is ambiguous, choose the simplest interpretation and leave a `// NOTE:` comment.
- Tests: each GENERATE THIS file must ship with at least one passing test.

## Repository layout

```
familyshield/
├── apps/
│   ├── parent-app/          # Flutter parent dashboard (mobile + web)
│   ├── child-android/       # Native Android agent (Kotlin)
│   ├── child-ios/           # Native iOS agent (Swift + Screen Time API)
│   └── agent-desktop/       # Windows/macOS agent (C# .NET 8)
├── services/
│   ├── api/                 # Node.js + TypeScript backend (Fastify)
│   ├── ai-engine/           # Python FastAPI NLP microservice
│   └── realtime/            # WebSocket gateway (Node.js + ws)
├── packages/
│   ├── shared-types/        # TypeScript types shared across services
│   ├── consent-sdk/         # COPPA/GDPR-K consent flow library
│   └── crypto/              # E2E encryption helpers
├── infra/
│   ├── docker/
│   ├── terraform/
│   └── k8s/
└── docs/
```

Tooling: pnpm workspaces + Turborepo (JS), Gradle (Android), SwiftPM (iOS), MSBuild (Desktop).
NOTE: `services/realtime/` and `infra/` are reserved for future passes; the realtime gateway
currently lives inside services/api (see §3.12). Create `infra/docker`, `infra/terraform`,
`infra/k8s` as empty dirs with a `.gitkeep` each.

## Wiring contracts (§12.3)

- API paths must match the route TODOs below exactly.
- WebSocket events use shape `{ type, payload, ts }` published to `family:${familyId}:events`. The
  gateway sends `{ type: "ready", familyId, ts }` as the first frame on every socket, after it has
  registered the socket for the family; no event frame precedes it (TR-05). Clients wait for it
  before treating the stream as live (e.g. to end a reconnect spinner).
- Agent internal calls are signed v2 (ADR-0014): `X-FamilyShield-Timestamp` (unix s),
  `X-FamilyShield-Nonce` (16–128 chars, unique) and `X-FamilyShield-Signature` =
  HMAC-SHA256(secret, `"<ts>.<nonce>.<body>"`), where `secret` is the device's per-device secret
  (minted at pair/claim). The server rejects |skew| > 300 s and any reused nonce. The global
  `INTERNAL_HMAC_SECRET` is a service credential only: v2 + `X-FamilyShield-Caller: ai-engine`.
  Body-only (v1) device signatures are refused unless `INTERNAL_SIGNING_ALLOW_V1=1` (rollout opt-in).
- Parent JWTs: `role: "parent"` always; `familyRole` (owner | co-parent | guardian) and `jti` on
  every token. Mutating routes check the Parent row's `permissions` (rules, alerts, devices,
  location); owners hold all; child create/erase, consent and invites are owner-only.

## Data isolation (§12.4 — non-negotiable)

Every route handler that reads a family-scoped resource must go through `requireFamily`
(services/api/src/middleware/requireFamily.ts). Write a test that attempts cross-family
access and expects 403.

## Consent gate (§12.5 — hard gate)

Creating a `Child` record must fail with HTTP 428 unless an active `ConsentRecord` exists
whose jurisdiction matches the family's region.

**Status and withdrawal (ADR-0008).** `GET /v1/family/children/:id/consent` returns
`{ active, reason?, jurisdiction?, consent?, records }`. `consent` is the active record when one
exists; `records` is up to 20 rows ordered by `grantedAt` descending **including revoked and
expired ones**, so a client can show the real method, dates and `revokedAt` after withdrawal
instead of inferring "no record". `POST /v1/family/children/:id/consent/revoke` sets
`revokedAt = now()` on every non-revoked row for the child, queues `consent_revoked` to each of its
devices and publishes the family event; from then on parent configuration writes and device
ingestion/reads answer 428, while safe-direction actions stay available. Withdrawal itself deletes
nothing: existing rows stay until the retention job (`RETENTION_DAYS`, default 90 for raw events;
`ROLLUP_RETENTION_DAYS`, default 365 for usage summaries; alerts and device commands are kept until
erasure) or until `DELETE /v1/family/children/:id` erases the child. A client must not claim that
withdrawal deletes or anonymises data.

## AI alerts pipeline (§12.6)

`POST /v1/alerts/internal` (HMAC-signed by ai-engine) → persist Alert →
`publishFamilyEvent(familyId, {type:"alert", payload})` → also enqueue push
(FCM for Android parent app, APNs for iOS).

## Non-goals for this pass

- Real Twilio/Stripe integration (stub interfaces only).
- Actual ML model training (load from disk or use fallback classifier).
- iOS App Store / Play Store submission workflows.
- Billing/subscription enforcement (leave a `BillingProvider` interface).

## Tests that must exist (§11)

```
services/api/test/auth.test.ts                 # register, login, MFA stub
services/api/test/rules.test.ts                # rule CRUD + family isolation
services/api/test/geofence.test.ts             # haversine + enter/exit transition
services/ai-engine/tests/test_analyze.py       # known-bad samples classify correctly
apps/child-android/.../RuleRepositoryTest.kt
apps/parent-app/test/auth_provider_test.dart
packages/consent-sdk/test/sms-plus.test.ts
```

NOTE on TS test strategy: `pnpm test` must pass WITHOUT a live Postgres/Redis. Mock
`@prisma/client` and `ioredis` via vitest `vi.mock`; test route logic, zod validation,
requireFamily isolation, consent gate, and pure helpers (e.g. haversine) directly.
Fastify routes can be exercised with `app.inject` where practical.

---

## §2 Shared Types — DONE (do not modify)

`packages/shared-types/src/index.ts` exports: UUID, ISODate, Platform, DeviceStatus,
Family, Parent, Child, Device, RuleSet, ScreenTimeRule, WebFilterRule, AppRule, Routine,
LocationPing, Geofence, Alert, ConsentRecord (exact shapes as originally specified).

## §3 Backend API (`services/api`)

- prisma/schema.prisma — DONE (models: Family, Parent, Child, Device, RuleSet, LocationPing,
  Geofence, Alert, ConsentRecord).
- src/db.ts — DONE. src/server.ts — DONE (registers cors, jwt, rate-limit, websocket,
  routes under /v1/*, realtime gateway, GET /health).
- src/realtime/gateway.ts — DONE: WS auth via ?token= JWT, psubscribe `family:*:events`,
  exports `publishFamilyEvent(familyId, event)`.
- src/routes/auth.ts — DONE. `POST /register`, `/login`, `/logout`, `/logout-all`, `/token/refresh`,
  `/reset/request`, `/reset/confirm`, `/mfa/enroll`, `/mfa/verify`, and (ADR-0023) `/mfa/recovery-codes`
  and `/mfa/recover`. See "MFA and account recovery" below for the second-factor contract.
- src/routes/family.ts — GENERATE THIS:
    GET /me; POST /children (428 without active consent); GET/PATCH/DELETE /children/:id
    (DELETE = GDPR erasure cascade — ADR-0013: every child-scoped table in one transaction,
    response carries `deletedDevices` + per-table `rows`, each device token revoked as on unpair);
    POST /children/:id/consent; GET /children/:id/consent (active status + `records` history,
    revoked/expired included); POST /children/:id/consent/revoke (ADR-0008); GET /export
    (GDPR export; simplest: JSON download is acceptable
    — leave NOTE).
- src/routes/reports.ts — GET /activity, GET /summary, GET /wellbeing/:childId; Phase 2c (ADR-0013):
    GET /usage?childId&days=1..366 (per-UTC-day series from `AppUsageDaily`, per-app split, zeros for
    empty days; `minutes` is the device-reported total when any device sent one, else the per-app sum)
    and GET /web?childId&days=1..90&limit&blocked=true|false&domain (browsing history from `WebVisit`).
    Nightly job `src/jobs/usageRollup.ts` reconciles yesterday from ActivityEvent and applies
    retention (`RETENTION_DAYS`, `ROLLUP_RETENTION_DAYS`).
- src/routes/devices.ts — GENERATE THIS:
    POST /register; GET /; GET /:id (+last 24h telemetry summary); POST /:id/command
    (lock, unlock, ring, sos_clear — Redis pub/sub channel `device:${deviceId}:commands`);
    POST /:id/push-token; DELETE /:id; PLUS POST /:id/telemetry (used by UsageReporter and
    TelemetryUploader — aggregates of per-app minutes / url logs).
- src/routes/rules.ts — GENERATE THIS: GET /:childId; PUT /:childId (zod-validated upsert);
    PATCH /:childId (partial). On every update publish to Redis `child:${childId}:rules`.
    Validate bedtime/school windows do not overlap unless explicitly allowed.
- src/routes/alerts.ts — GENERATE THIS: GET / (paginated, filter childId/severity/category);
    POST /:id/ack; POST /internal (HMAC-signed, X-FamilyShield-Signature). On create:
    persist → publishFamilyEvent → enqueue push (stub provider is fine, NOTE).
- src/routes/location.ts — GENERATE THIS:
    POST /ping (device-authenticated); GET /:childId/latest; GET /:childId/history;
    GET /geofences/:childId; POST /geofences; DELETE /geofences/:id.
    Geofence evaluation: on each ping, haversine distance to all child geofences; on
    enter/exit transition raise Alert category "geofence".
- src/middleware/requireFamily.ts — GENERATE THIS: preHandler factory that loads the
  family-scoped resource by request param (child/device/geofence/alert), returns 403 when
  resource.familyId !== req.user.familyId, attaches resource to the request.
- scripts/seed.ts — GENERATE THIS: idempotent seed — Family "Demo Family" (US); parent
  demo@familyshield.dev / "CorrectHorseBatteryStaple!"; Child "Alex" born 2013 with valid
  ConsentRecord (sms_plus, US); Device "Pixel 7a" (android, pushToken "demo-token");
  default RuleSet (180 min daily, bedtime 21:00–07:00, blockedCategories [pornography,
  gambling], safeSearchEnforced true); geofences "Home" and "School"; three sample alerts
  (info/warning/critical). Running twice must not duplicate rows.
- Dockerfile — DONE. Package scripts: db:migrate = `prisma migrate deploy` (therefore a
  prisma/migrations/0001_init/migration.sql matching schema.prisma must be generated),
  db:seed = `tsx scripts/seed.ts`.

### MFA and account recovery (ADR-0023)

MFA is optional and off by default (ADR-0004). When it is on, the account has two things the parent
holds: the authenticator (TOTP) and, from the moment it is switched on, a set of ten one-time
recovery codes.

| Surface | What it does | What it refuses |
|---|---|---|
| `POST /v1/auth/mfa/enroll` | mints a TOTP secret and its `otpauth://` URL; replacing an existing secret needs the account password or a current TOTP (#139) | a bare session for a replacement (`401 reauth_required`) |
| `POST /v1/auth/mfa/verify` | enables MFA, revokes every session, and **returns ten recovery codes — the only time the plaintext exists** | a wrong TOTP (`401 invalid_code`), a verify with no secret (`400 mfa_not_enrolled`) |
| `POST /v1/auth/mfa/recovery-codes` | issues/replaces the batch (same re-authentication rule as a secret replacement) and returns the new ten codes | no proof of parentage when a secret exists (`401 reauth_required`) |
| `POST /v1/auth/mfa/recover` | takes `{email, password, code}`; clears `mfaSecret`/`mfaEnabled`, spends the code, deletes the rest of the batch, revokes every session, emails a notice, and returns `{recoveryToken}` | everything else with the same `401 {"error":"invalid_recovery"}` — unknown address, wrong password, wrong/spent code, MFA not enabled |
| `POST /v1/auth/mfa/enroll` + `/verify` with `mfa_recovery` | the 15-minute recovery token re-enrols and re-verifies | once `mfaEnabled` is true again, and every other route (`401 unauthorized`) |

Code format: 16 Crockford base32 characters (80 bits), no `I`, `L`, `O`, `U`, displayed
`XXXX-XXXX-XXXX-XXXX`. Normalisation before hashing: uppercase, separators stripped, `I`/`L` read as
`1` and `O` as `0`. Storage: `ParentMfaRecoveryCode.codeHash` = SHA-256 of the normalised code; the
plaintext is never stored, logged or returned a second time. One-time use is the
`updateMany({where:{id, usedAt:null}})` count, so two concurrent requests cannot both spend a code;
a successful recovery deletes the remaining rows. A parent who loses the codes and the authenticator
is still locked out until the support path (Option B) is decided — the API offers no other route, and
`/reset/confirm` deliberately does **not** clear MFA.

The recovery token is not a session: `{sub, purpose:"mfa_recovery", jti}`, 15 minutes, backed by
Redis `mfa:recovery:<jti>` → parentId (deleted on a successful verify), no `familyId` and no `role`.
`requireJwt` still rejects every `purpose` token (#146/#147); only the two enrolment routes use
`requireParentOrMfaRecovery`. The parent app has no MFA screen yet, so the codes are reachable only
through the API today — the Flutter work is a follow-up, not part of this contract.

## §4 AI Engine (`services/ai-engine`)

- app.py, requirements.txt, Dockerfile — DONE.
- model.py — GENERATE THIS: `analyze_text(text, context, child_age)`:
    1. Loads fine-tuned DistilBERT from MODEL_PATH env var (lazy singleton, torch.no_grad()).
    2. Multi-label probabilities for ["cyberbullying","self_harm","grooming","violence",
       "sexual_content","substance_use","hate_speech","safe"].
    3. Rules layer: regex for known grooming phrases, phone numbers, meeting requests.
    4. Severity: >=0.85 critical, >=0.6 warning, else info.
    5. flagged = severity in (warning, critical).
    6. explanation references top-2 categories.
    Fallback keyword classifier when model files are missing (dev mode). IMPORTANT: torch /
    transformers imports must be lazy (inside the loader) so the module imports and tests run
    on machines without them (e.g. Python 3.13). Tests in tests/test_analyze.py must exercise
    the fallback path and pass without torch/fastapi installed.

## §5 Android Child Agent (`apps/child-android`)

DONE: app/build.gradle.kts, AndroidManifest.xml, res/xml/accessibility_config.xml,
AccessibilityMonitorService.kt, FirebaseMessagingSvc.kt, BootReceiver.kt.
TODOs inside DONE files: FirebaseMessagingSvc.onNewToken → POST /v1/devices/:id/push-token;
BootReceiver → schedule RuleRepository sync + UsageReporter WorkManager jobs.

GENERATE THIS:
- data/RuleRepository.kt — persists latest RuleSet locally (DataStore, JSON); subscribes to
  FCM topic `child:<childId>:rules`; `evaluate(packageId): Decision` using routine windows,
  app rules, daily counters, bedtime/school hours; Decision = ALLOW/BLOCK/TIME_LIMIT_REACHED;
  counters reset at local midnight (WorkManager); thread-safe (Mutex).
- enforcement/AppBlocker.kt — showBlockScreen(pkg) / showTimeLimitScreen(pkg): full-screen
  BlockActivity; "Request access" posts /v1/alerts/internal category "app_blocked"; debounce
  2s per pkg; ignore own overlay package.
- services/LocationService.kt — foreground service, FusedLocationProviderClient,
  PRIORITY_BALANCED_POWER_ACCURACY; adaptive interval (5 min stationary / 30 s moving >5 m/s);
  batch POST /v1/location/ping every 60 s; Room DB for unsent pings; high-priority
  notification.
- telemetry/UsageReporter.kt — recordForeground(pkg, ts) → Room; WorkManager every 15 min
  aggregates per-app minutes/total/unlocks; POST /v1/devices/:id/telemetry; UsageStatsManager
  backfill.
- commands/CommandDispatcher.kt — handle: lock, unlock, ring, sos_clear, rules_updated,
  locate_now.

Also needed to compile (not in spec, create following conventions): FamilyShieldApp
(@HiltAndroidApp Application), BlockActivity, Room DB classes, Retrofit API interfaces,
Hilt modules, res/values/strings.xml (accessibility_description, app_name), root
settings.gradle.kts + build.gradle.kts. Test: RuleRepositoryTest.kt (JUnit; exercise
evaluate() logic — pure JVM tests must not need Android framework: put evaluation logic in a
plain Kotlin class where possible).

## §6 iOS Child Agent (`apps/child-ios`)

Package.swift — DONE (SwiftPM library + test target, iOS 16).
GENERATE THIS:
- ScreenTimeController.swift — Screen Time API: requestAuthorization(for: .child);
  applyBlockedApps via ManagedSettingsStore().shield.applications; applyWebFilter;
  scheduleBedtime via DeviceActivityCenter + DeviceActivitySchedule; guards non-authorized.
- ShieldConfiguration.swift — ShieldConfigurationDataSource: title "Blocked by FamilyShield",
  subtitle w/ rule reason, primary "Ask parent", secondary "OK"; secondary action dismisses
  shield + logs request to API.
- DeviceActivityMonitor.swift — DeviceActivityMonitor subclass: eventDidReachThreshold →
  alert (category "screen_time_exceeded"); intervalDidStart/End apply/clear bedtime shields;
  one DeviceActivityName per routine ID.

## §7 Parent App (`apps/parent-app`, Flutter)

DONE: pubspec.yaml, lib/main.dart, lib/app.dart (GoRouter routes: /login, /,
/child/:id, /child/:id/rules, /alerts, /map; redirect on auth state), lib/api/client.dart
(Dio + secure-storage JWT interceptor; API_BASE via --dart-define, default http://10.0.2.2:3000).

GENERATE THIS:
- providers/auth_provider.dart — AuthState + AuthNotifier (StateNotifier): login, register,
  logout, bootstrap (GET /v1/family/me with existing token); global authProvider.
- features/auth/login_screen.dart — email/password, Sign in → authProvider.login, link to
  registration.
- features/dashboard/dashboard_screen.dart — AppBar + alerts badge (GET /v1/alerts?ack=false);
  grid of child cards (avatar, name, device status pill, battery, location snippet, screen
  time bar); pull-to-refresh; FAB "Add child" (consent-first flow).
- features/children/child_detail_screen.dart — tabs Overview/Apps/Location/Alerts; "Edit
  rules" → /child/:id/rules.
- features/rules/rules_editor_screen.dart — tabs: Screen time (sliders + bedtime pickers),
  Web filter (categories + allow/block lists), Apps (allow/block/time-limit segmented),
  Routines; Save → PUT /v1/rules/:childId, invalidate rulesProvider.
- features/map/family_map_screen.dart — GoogleMap markers per child colored by status;
  geofence circles; marker tap → bottom sheet (last update, address, Ring/Lock buttons);
  WebSocket /v1/ws live updates.
- features/alerts/alerts_screen.dart — infinite scroll grouped by day; severity colors;
  swipe-to-ack (POST /v1/alerts/:id/ack); detail view per category.
- test/auth_provider_test.dart — must pass under `flutter test` (mock Dio layer; do not
  hit network).

Additional providers (familyProvider, rulesProvider, alertsProvider, locationProvider,
wsProvider) should live in lib/providers/ and use the ApiClient from lib/api/client.dart.

## §8 Desktop Agent (`apps/agent-desktop`, C# .NET 8)

DONE: FamilyShield.Agent.csproj (Worker SDK, net8.0-windows; refs: Hosting, Http,
Microsoft.Data.Sqlite, System.Reactive, Titanium.Web.Proxy), Program.cs (registers
ApiClient HttpClient + hosted services WebFilterProxy, ProcessMonitor, ScreenTimeEnforcer,
RuleSyncService, TelemetryUploader; singleton LocalRuleStore).

GENERATE THIS (all under Services/, plus ApiClient):
- ApiClient.cs — typed HttpClient w/ device JWT: PostTelemetry, GetRules, PostAlert,
  GetCommands.
- LocalRuleStore.cs — SQLite: tables ruleset (single-row JSON), blocklist_categories,
  blocklist_domains, app_usage (per-day per-process minutes), url_log; ShouldBlock(host,url);
  MinutesUsedToday(processName); Sync(RuleSet).
- WebFilterProxy.cs — Titanium proxy on 127.0.0.1:8877; BeforeRequest → ShouldBlock →
  200 HTML "Blocked by FamilyShield"; SafeSearch rewrite for google/bing/youtube; log to
  SQLite; WinINET registry proxy autoconfig.
- ProcessMonitor.cs — poll processes every 5 s; match AppRules; kill or topmost overlay;
  foreground window title via GetForegroundWindow/GetWindowText.
- ScreenTimeEnforcer.cs — daily counters from LocalRuleStore; limit reached → topmost
  full-screen overlay; bedtime → LockWorkStation() P/Invoke.
- RuleSyncService.cs — poll GET /v1/rules/:childId every 60 s → LocalRuleStore.Sync();
  also GET /v1/devices/:id/commands dispatch.
- TelemetryUploader.cs — every 5 min POST url_log + app_usage batches to
  /v1/devices/:id/telemetry; mark uploaded.

NOTE: keep everything compiling on net8.0-windows; WPF overlay may be replaced by a plain
topmost WinForms/blank window if simpler — simplest interpretation, leave NOTE.

## §9 Consent SDK (`packages/consent-sdk`)

DONE: package.json, src/index.ts (ConsentMethod, VerifiableParentalConsent,
ConsentProvider, requiredConsentAge), test/sms-plus.test.ts (age-matrix tests).
GENERATE THIS: src/sms-plus.ts — SMS+ (text-plus) VPC provider per COPPA: initiate() sends
6-digit SMS code (Twilio interface stubbed), challengeId = HMAC(code|childId|ts); verify()
requires code AND a second factor: (a) last-4 SSN, (b) signed consent PDF, or (c) credit-card
micro-charge stub; evidence persisted in ConsentRecord.evidence. Add further tests in
test/sms-plus.test.ts for challenge/verify round-trip (crypto via node:crypto only).

## §10 Crypto (`packages/crypto`)

GENERATE THIS: src/index.ts —
- generateFamilyKey(): 32-byte AES-256 key (base64)
- encryptForFamily(plaintext, key): AES-256-GCM, random IV → { iv, ciphertext, tag }
- decryptForFamily(payload, key)
- deriveDeviceKey(masterKey, deviceId): HKDF-SHA256
- hmacSign(body, secret): for /v1/internal endpoints (hex HMAC-SHA256)
Use node:crypto only. Add round-trip + HMAC tests (vitest) so `pnpm test` covers it.
NOTE: goal — sensitive telemetry encrypted at rest with the family key; server holds
ciphertext only.

## §12 Explicit instructions (priority order)

1. Fix all `// TODO: KIMI CODE` blocks in DONE files (they must compile).
2. Generate GENERATE THIS files; follow conventions; manifests must reflect any dep change.
3. Wire services: API paths match route TODOs; WS shape `{type, payload, ts}` on
   `family:${familyId}:events`; internal calls carry X-FamilyShield-Signature.
4. Data isolation via requireFamily + a cross-family 403 test.
5. Consent hard gate: create Child without active matching ConsentRecord → 428.
6. AI alerts pipeline: POST /v1/alerts/internal (HMAC) → persist → publishFamilyEvent →
   push enqueue (FCM/APNs stubs).
7. No new product features; simplest interpretation + NOTE.
8. One-line docstrings on public functions.
9. Every GENERATE THIS file ships ≥1 passing test.

## §13 Acceptance checklist

- [ ] docker compose up starts postgres, redis, api, ai-engine
- [ ] pnpm --filter api db:migrate && db:seed succeeds
- [ ] pnpm test passes across all TS packages
- [ ] pytest services/ai-engine passes
- [ ] ./gradlew :app:testDebugUnitTest passes
- [ ] flutter test passes
- [ ] dotnet build succeeds
- [ ] E2E: register → child+consent → device → PUT rules → agent sync → telemetry → alert
- [ ] Cross-family access test returns 403
- [ ] Missing-consent test returns 428


---

# §14 Test-release pass — device pairing + shareable builds (2026-09-14)

Goal: a tester-installable release for **Android (parent app + child agent) and Windows
(desktop agent)**; iOS is explicitly deferred. All agents must work without Firebase/FCM
(HTTP polling fallbacks) and against a **configurable server URL** (testers host the backend
on the owner's PC — LAN or tunnel).

## §14.1 Pairing contract (implemented in services/api)

```
POST /v1/devices/pair        (parent JWT + `devices` permission; requireFamily child, source body)
  body: { childId }
  → 201 { code: "<6 digits>", expiresAt: <ISO> }
  Storage: Redis key `pair:<code>` = JSON { childId, familyId }, TTL 600 s.
  Collision: regenerate on SET NX failure (max 5 tries).

POST /v1/devices/pair/claim  (NO auth)
  body: { code, platform, model, osVersion, deviceName?, pushToken? }
  → 201 { device, token, childId, familyId }
  token = device JWT, claims { sub: deviceId, deviceId, childId, familyId, role: "device" },
  expiresIn "10y".
  Consume code with GET then DEL (Redis 5.0 has no GETDEL). Unknown/expired code →
  404 { error: "invalid_or_expired_code" }. Device row created with status "online",
  lastSeen now. Family/child ids come from the Redis payload, never from the client.
```

Device JWTs must work on existing agent endpoints: `GET /v1/rules/:childId` (its own child
only), `GET/POST /v1/devices/:id/commands`, `POST /v1/devices/:id/telemetry`,
`POST /v1/devices/:id/push-token`, `POST /v1/location/ping` (a parent JWT or a device JWT; a
device JWT may ping only its own child, and a parent-supplied `deviceId` must be a row of the
named child — 403 `device_mismatch` otherwise). A signature-valid JWT with any other role or
purpose (e.g. the password-reset token) is **401**: `jwtVerify()` proves the signature, not the
right to write location data (audit 2026-10-18). Parent-only endpoints keep requiring the parent
role (req.user.role !== "parent" → 403): enforce in requireAuth/requireFamily where missing.

Tests: extend services/api/test — pair → claim round-trip (201 + device row with correct
family), wrong code 404, expired code 404, parent-JWT endpoints reject device tokens (403),
agent endpoints accept device tokens.

## §14.2 Android child agent

- `setup/PairingActivity.kt` (launcher, exported): fields server URL + pairing code +
  device name; on Pair → POST {base}/v1/devices/pair/claim; store {baseUrl, deviceJwt,
  deviceId, childId} in AgentSettings DataStore; then start LocationService + schedule
  workers (WorkScheduler.scheduleAll()) and finish with "Setup complete — enable the
  FamilyShield accessibility service" instructions. If already paired, jump straight to a
  status screen showing child name/id + "Re-pair" button.
- Dynamic base URL: OkHttp interceptor rewrites the host of every request to the stored
  baseUrl (Retrofit built with a placeholder base). Apply to existing ApiService.
- FCM-free operation (test builds have no google-services.json): RulesSyncWorker interval
  6 h → 60 min is NOT enough — add `CommandPollWorker` (every 60 s, network-constrained)
  hitting GET /v1/devices/:id/commands with the device JWT and dispatching via
  CommandDispatcher; make RulesSyncWorker periodic at 60 min AND trigger an immediate
  refresh after pairing. Keep FCM receivers (harmless when FCM is absent).
- Signing: sign the release build with the debug key so the APK is installable:
  `signingConfig = signingConfigs.getByName("debug")` in the release build type.
- Build artifact: `gradlew :app:assembleRelease` → copy
  app/build/outputs/apk/release/app-release.apk to C:\KARIM\familyshield\dist\FamilyShield-ChildAgent.apk
- Keep `// NOTE:` on the dev-HMAC fallback (pairing supersedes it).

## §14.3 Windows desktop agent

- Replace env-var identity with `AgentConfig` (JSON file `agent.config.json` beside the
  exe, path from AppContext.BaseDirectory; env vars remain as overrides): { apiBase,
  deviceJwt, deviceId, childId }. ApiClient base address + token come from AgentConfig.
- First run (no config): WinForms dialog (reuse the existing overlay thread approach):
  server URL + pairing code → POST /v1/devices/pair/claim → write config → start services.
  Console fallback if no interactive session.
- RuleSyncService/TelemetryUploader/ProcessMonitor read ids from AgentConfig instead of
  env (keep env override). Verify `dotnet build` + the xunit tests still pass.

## §14.4 Parent app (Flutter)

- Server URL: a "Server" field on the login screen (defaults to the API_BASE define),
  persisted with shared_preferences; applied at startup AND at login by setting
  `api.raw.options.baseUrl` (client.dart stays untouched). wsProvider must derive its URL
  from the runtime dio base (read apiClientProvider.raw.options.baseUrl), not the const.
- Pair a device: button on the child detail Overview tab → POST /v1/devices/pair →
  full-screen `PairingQrScreen` (`apps/parent-app/lib/features/pairing/`) showing the code as
  a QR, the same 6-digit code in large type, copy and Regenerate actions, and a countdown to
  the server-supplied `expiresAt` (TTL 600 s, `services/api/src/routes/devices.ts`); at zero
  the QR/code are hidden and copy is disabled until Regenerate. The typed-code path is
  unchanged. `familyProvider` is invalidated on return so a newly claimed device appears.
  The QR carries a versioned payload, encoded/decoded by pure Dart
  `pair_qr_payload.dart`:
  ```
  osra://pair?v=1&code=<6 digits>&host=<API base URL, percent-encoded>
  ```
  `host` is the parent app's runtime API base (`api.raw.options.baseUrl`), so the scanner
  learns the server as well as the code. Decoders must reject unknown `v` and non-http(s)
  hosts. The child agent consumes the same payload: `PairQrScanActivity`
  (`apps/child-android/.../setup/`) reads the QR with CameraX and the bundled ML Kit model,
  returns the raw string, and pure-Kotlin `PairQrPayload` applies the same rules (v1 only,
  six digits, absolute http(s) host with no query or fragment). A scan fills the server and
  code fields, shows the host and a masked code, and pairs only after an explicit
  **Confirm and pair**; a denied camera or a refused code returns to the typed form with the
  reason. The typed-code path is unchanged.
- Build artifact: `flutter build apk --release` (debug-signed, installable) → copy
  build\app\outputs\flutter-apk\app-release.apk to
  C:\KARIM\familyshield\dist\FamilyShield-Parent.apk

## §14.5 Definition of done

- `pnpm --filter api vitest run` green with the new pairing tests.
- `gradlew :app:assembleRelease` succeeds; APK copied to dist/.
- `flutter test` still green; `flutter build apk --release` succeeds; APK in dist/.
- `dotnet build` + xunit tests green.
- Live re-run of scripts/e2e.mjs (backend up) still 32/32, plus a manual pairing
  round-trip: pair → claim with curl (device JWT) → GET rules with that token (200).
