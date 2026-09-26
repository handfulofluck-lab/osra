<div align="center">

# OSRA · أسرة

**Cross-platform parental-control suite — Android, Windows, iOS (in progress), with an AI-assisted safety backend.**

Parent dashboard · Child agents · Web filtering · Screen-time & bedtime enforcement ·
AI social-safety monitoring with an encrypted snippet vault · Location & geofences · SOS

</div>

---

## Why OSRA

OSRA is built to match or exceed Qustodio Premium and Google Family Link on Android and
Windows, with an honestly-documented iOS roadmap. Everything a family needs — and nothing
that requires a rooted device or a corporate MDM:

- **Real enforcement on Android** via the accessibility service (app blocking, time
  limits, routines, bedtime windows) — no root, no device-owner mode required for the
  test build.
- **A real Windows agent** — local filtering proxy with SafeSearch rewrite, process
  blocking, screen-time overlay, bedtime workstation lock, opt-in HTTPS inspection.
- **AI that helps parents talk to their kids** — WhatsApp/social concern detection with
  bounded, encrypted snippets (not full-chat surveillance) and conversation-coach cards
  in English and العربية.
- **Privacy by architecture** — per-family data isolation, COPPA/GDPR-K consent gate
  (HTTP 428 until consent is recorded), per-device HMAC-signed agent alerts,
  encrypted snippet vault, GDPR export & erasure APIs.

## Repository layout

```
familyshield/
├── apps/
│   ├── parent-app/       # Flutter parent dashboard (Android today; iOS/web-ready codebase)
│   ├── child-android/    # Kotlin child agent (accessibility enforcement, location, comms log)
│   ├── child-ios/        # Swift child agent — Screen Time API + pairing flow (needs macOS to build)
│   ├── agent-desktop/    # C# .NET 8 Windows agent (self-contained single file)
│   └── agent-macos/      # macOS agent scaffolding (roadmap)
├── services/
│   ├── api/              # Node.js + TypeScript backend (Fastify, Prisma, JWT+HMAC auth)
│   ├── ai-engine/        # Python FastAPI NLP microservice (concern classification)
│   └── realtime/         # WebSocket gateway (served by the API; standalone split planned)
├── packages/
│   ├── shared-types/     # TypeScript contracts shared across services
│   ├── consent-sdk/      # COPPA / GDPR-K consent flow library
│   └── crypto/           # E2E/vault encryption helpers
├── docs/                 # SPEC, competitive analysis, world-class addendum, test guides
├── infra/                # docker / k8s / terraform
└── .github/workflows/    # CI
```

## Feature highlights (29 shipped — see `docs/SPEC-ADDENDUM-WORLD-CLASS.md`)

Default-on 13-category web/app protection · pause internet one-tap · WhatsApp/social AI
monitoring with encrypted snippet vault · calls & SMS timeline · contact allowlist ·
install alerts with one-tap block · always-allowed apps · bonus time · wind-down · child
SOS (phone quick-tile / PC hotkey) · multi-parent invites · tamper & VPN alerts · usage
reports with charts · wellbeing score · live activity chip · app insights · digest
preferences · conversation coach (EN/عربي) · routines · geofences · ring/lock/unlock ·
MFA (optional TOTP) · refresh-token rotation with reuse detection.

## Quickstart (development)

**Prereqs:** Node 20 + pnpm 9, Docker (for Postgres/Redis), Flutter 3.x (parent app),
JDK 17 + Android SDK (child agent + Flutter builds), .NET 8 SDK (Windows agent),
Python 3.11+ (ai-engine). Portable toolchains live under `C:\KARIM\tools` on the dev box.

```bash
# 1. Backend dependencies
corepack enable && pnpm install

# 2. Datastores
docker compose up -d postgres redis

# 3. Database schema + demo seed (demo@familyshield.dev / CorrectHorseBatteryStaple!)
pnpm db:migrate && pnpm db:seed

# 4. API + AI engine
pnpm --filter @familyshield/api dev          # http://localhost:3000
cd services/ai-engine && pip install -r requirements.txt && uvicorn app:app --port 8000

# 5. Apps (see docs/test-guides/ for the full tester walkthrough)
cd apps/parent-app && flutter run             # parent dashboard
cd apps/child-android && ./gradlew installDebug
cd apps/agent-desktop && dotnet run           # Windows agent (pairing window on first run)
```

`GET /health` → liveness. `GET /health/deep` → `{ok, db, redis}` readiness
(returns 503 naming the dependency that is down).

## Testing

| Suite | Scope | Status (2026-09-19) |
|---|---|---|
| API vitest | routes, auth, token hygiene, blocklists | 193/193 |
| Flutter `flutter test` | parent app widgets/providers | 94/94 |
| Android JVM tests | agent policies (block/allow/routines/HMAC) | 151/151 |
| Desktop xunit | Windows agent services | 168/168 |
| AI pytest | classifier + API | 18 passed / 1 skipped |
| Live e2e (`services/api/scripts/e2e.mjs`) | pairing → alerts → rules against a running stack | 50/50 |

```bash
pnpm --filter @familyshield/api test        # API unit suites
cd services/api && node scripts/e2e.mjs     # live e2e (needs stack + INTERNAL_HMAC_SECRET, VAULT_KEY)
flutter test                                 # parent app
./gradlew testDebugUnitTest                  # Android agent (ANDROID_HOME required)
dotnet test tests/FamilyShield.Agent.Tests   # Windows agent
pytest services/ai-engine/tests              # AI engine
```

## Security model

- Parents authenticate with email + password (argon2); **MFA is optional** TOTP,
  enforced only when a parent enables it.
- Access tokens are short-lived JWTs; refresh tokens rotate with **reuse detection**
  (a replayed refresh token revokes all of that parent's sessions). `/logout`,
  `/logout-all`, and revocation on password-reset/MFA-enable.
- Child-device agents authenticate with per-device JWTs **revoked on unpair**, and sign
  agent alerts with **per-device HMAC secrets** delivered once at pairing.
- Family isolation on every data route (cross-family access → 403); child profiles are
  consent-gated (428) with a recorded `ConsentRecord` (COPPA / GDPR-K).
- The snippet vault is AES-encrypted server-side (`VAULT_KEY`); the server stores
  bounded excerpts, never full chat histories.
- WebSocket connections use single-use tickets (`POST /v1/ws-ticket`) so JWTs never
  appear in URLs.

## Documentation

| Document | Contents |
|---|---|
| `docs/SPEC.md` | Full product & API specification |
| `docs/SPEC-ADDENDUM-WORLD-CLASS.md` | The 29 world-class features + implementation contracts |
| `docs/COMPETITIVE-ANALYSIS.md` | Qustodio / Family Link feature mapping |
| `docs/test-guides/README-TESTERS.md` | Test-release readme (what's included, known limits) |
| `docs/test-guides/INSTALLATION-GUIDE.md` / `.html` | Step-by-step tester setup (backend → pairing → checklist) |
| `docs/test-guides/SHIP-NOTES.md` | Per-feature test recipes |
| `docs/test-guides/WORLD-CLASS-CHANGELOG.md` | Feature changelog |
| `docs/test-guides/PUBLISHING-READINESS.md` | Store/publishing checklist |
| `docs/test-guides/HANDOFF-FOR-TESTING.md` | Engineering handoff, incident log, suite state |
| `apps/child-ios/QA-IOS.md` · `IOS-BUILD-NOTES.md` | iOS status (requires macOS/Xcode) |
| `docs/test-guides/CHROMEBOOK-KINDLE-PATH.md` | Chromebook / Kindle roadmap |

## Honest current limitations

- **iOS agent is source-complete but not compiled** — Apple Screen Time APIs require a
  macOS + Xcode build host; pairing flow and agent sources are in `apps/child-ios`.
- No push notifications in test builds (agents poll ~60 s); FCM/APNs is a roadmap item.
- Android pause-internet is overlay + app-blocking today; VPN-sinkhole is the
  production path. HTTPS inspection on Windows is opt-in (`FS_HTTPS_INSPECT=1`).
- Location was verified functionally but needs a physical-phone GPS check (emulator
  GPS injection never reaches the agent).
- Test APKs are debug-signed; store signing, AABs, privacy policy and permission
  declarations are tracked in `PUBLISHING-READINESS.md`.

## License

Proprietary — © 2026 OSRA. All rights reserved. No license is granted by this repository;
contact the maintainers before reusing any part of it.
