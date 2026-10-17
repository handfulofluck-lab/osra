<div align="center">

# OSRA · أسرة

**Cross-platform parental-control suite — Android, Windows, iOS (in progress), with an AI-assisted safety backend.**

Parent dashboard · Child agents · Web filtering · Screen-time & bedtime enforcement ·
AI social-safety monitoring with an encrypted snippet vault · Location & geofences · SOS

[![CI](https://github.com/handfulofluck-lab/osra/actions/workflows/ci.yml/badge.svg)](https://github.com/handfulofluck-lab/osra/actions/workflows/ci.yml)
[![iOS CI](https://github.com/handfulofluck-lab/osra/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/handfulofluck-lab/osra/actions/workflows/ios-ci.yml)
[![workflow-lint](https://github.com/handfulofluck-lab/osra/actions/workflows/workflow-lint.yml/badge.svg)](https://github.com/handfulofluck-lab/osra/actions/workflows/workflow-lint.yml)

[Changelog](CHANGELOG.md) · [Testing guide](docs/TESTING.md) · [Decisions](docs/adr/README.md) ·
[QA state](docs/QA/QA-REPORT-2026-10-11.md) · [Working agreement](AGENTS.md) · [Doc map](docs/README.md)

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
SOS (phone quick-tile / PC hotkey) · multi-parent invites · tamper & VPN alerts · **Device Admin +
parent PIN** (uninstall/re-pair/deactivate need the PIN; removal alerts the parent — ADR-0010) · usage
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

Two kinds of gate, deliberately separate (see [`docs/adr/0005`](docs/adr/0005-adversarial-acceptance-gate.md)):

- **Feature suites** confirm the behaviour we intended.
- **The adversarial probe** tries to break the documented invariants against a live stack. It is the
  **merge gate** — a green unit suite is not evidence that an invariant holds.

| Suite | Scope | Status (2026-10-15) |
|---|---|---|
| **Adversarial probe** (`services/api/scripts/qa-probe.mjs`) | family isolation, per-device identity, consent gate, revocation, token hygiene, alert coverage, input bounds, error hygiene | **73 passed · 0 failed · 3 targets** |
| API vitest | routes, auth, token hygiene, blocklists, content | 205/205 |
| Flutter `flutter test` (+ `flutter analyze`) | parent app widgets/providers, layout at 320×568 | 94/94, analyze clean |
| Android JVM tests | rule engine, counters, monitored apps, HMAC logic | 151/151 |
| Desktop xunit | Windows agent services | 170/170 |
| AI pytest | classifier + API smoke | 21 passed |
| Live e2e (`services/api/scripts/e2e.mjs`) | pairing → rules → alerts → commands → export | 50/50 |
| Hardware (physical device) | first-run crash, FGS start, location upload, overlays | procedure in [`docs/TESTING.md`](docs/TESTING.md) §5 |

```bash
pnpm --filter @familyshield/api test        # API unit suites
cd services/api
INTERNAL_HMAC_SECRET=<...> node scripts/qa-probe.mjs   # the merge gate
INTERNAL_HMAC_SECRET=<...> VAULT_KEY=<...> node scripts/e2e.mjs
cd ../parent-app && flutter test && flutter analyze
cd ../child-android && ANDROID_HOME=... ./gradlew testDebugUnitTest
cd ../agent-desktop && dotnet test tests/FamilyShield.Agent.Tests
cd ../../services/ai-engine && pytest tests -q
node scripts/check-workflows.mjs --strict   # a rejected workflow file means zero jobs run
```

Full procedure, failure interpretation and the environment traps that have cost time here:
[`docs/TESTING.md`](docs/TESTING.md).


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
  appear in URLs; the first frame on every socket is `{type:"ready", familyId, ts}`, sent once the
  socket is registered for the family.

## Documentation

Start at [`docs/README.md`](docs/README.md) — the full map. The essentials:

| Document | Contents |
|---|---|
| [`CHANGELOG.md`](CHANGELOG.md) | What changed, when, in which PR, and what is verified vs not |
| [`docs/TESTING.md`](docs/TESTING.md) | Every suite and gate: how to run, how to read failures, hardware procedure, environment traps |
| [`docs/adr/`](docs/adr/README.md) | Architecture decision records — the **reasoning** behind decisions, with rejected alternatives and costs |
| [`AGENTS.md`](AGENTS.md) | Binding working agreement (roles, definition of done, PR/review protocol, device hygiene) |
| [`docs/SPEC.md`](docs/SPEC.md) | Full product & API specification |
| [`docs/SPEC-ADDENDUM-WORLD-CLASS.md`](docs/SPEC-ADDENDUM-WORLD-CLASS.md) | The 29 world-class features + implementation contracts |
| [`docs/SPEC-CONTENT-SAFETY.md`](docs/SPEC-CONTENT-SAFETY.md) · [`docs/SPEC-AI-CONCERN-ENGINE.md`](docs/SPEC-AI-CONCERN-ENGINE.md) | Track 1 (content filtering) and Track 2 (concern engine) designs |
| [`docs/COMPETITIVE-ANALYSIS.md`](docs/COMPETITIVE-ANALYSIS.md) | Qustodio / Family Link feature mapping |
| [`docs/QA/`](docs/QA/) | QA report, prioritised work queue, raw platform audits, agent discussion log |
| [`docs/test-guides/`](docs/test-guides/) | Tester-facing guides (install, per-feature recipes, publishing readiness, iOS CI) |
| [`apps/child-ios/QA-IOS.md`](apps/child-ios/QA-IOS.md) | iOS status and what still requires a Mac |

## How we work

Implementation and verification are separate roles, and the process controls are engineered rather than
promised: `main` is PR-only, a PR opens with a **restatement of the ask in the author's own words**, the
review answers point by point with evidence, gates must be able to fail, and anything that cannot be
verified where it was written is stated as such. Details:
[`AGENTS.md`](AGENTS.md) and [`docs/adr/0007`](docs/adr/0007-engineered-process-controls.md).

## Honest current limitations

- **Location works but has limits.** On the physical device (Android 16) the foreground service starts
  from the permission dialog and on relaunch, and pings reach the server (`201` + a persisted row).
  Still open: geofence/GPS *quality* has not been assessed (only that samples flow), Android's
  pause-internet is overlay-based, and iOS location is unverified.
- **Android shows two permission dialogs in a row** during pairing (location, then notifications); the
  location service starts once the last one is dismissed. Correct, but easy to misread as "nothing
  happened" — a tester-facing note, not a defect.
- **iOS is compiled only by CI** (SwiftPM + simulator build on a macOS runner). No Screen Time
  behaviour has been verified on a real device.
- Legacy body-only (v1) agent signatures are **refused by default** (probe check `J7`); an operator
  rolling out v2 agent builds can set `INTERNAL_SIGNING_ALLOW_V1=1` for the duration, and the probe
  then reports `J7` as a target so the state is never silent. Replay protection (`J2`), consent
  revocation (`J3`) and the global-secret fallback (`J6`) are closed and gated (ADR-0014). The Android
  v2 signer is verified on hardware (TR-07, Galaxy Z Flip4 / Android 16); the Windows and iOS signers
  by their unit tests against the same reference vector only.
- No push notifications in test builds (agents poll ~60 s); FCM/APNs is a roadmap item.
- Raw activity, browsing, social and location rows are kept **90 days** (rollups one year) by a
  nightly job — a global setting today, not per family (ADR-0013).
- Android pause-internet is overlay + app-blocking today; VPN-sinkhole is the production path. HTTPS
  inspection on Windows is opt-in (`FS_HTTPS_INSPECT=1`).
- Test APKs are debug-signed; store signing, AABs, privacy policy and permission declarations are
  tracked in [`docs/test-guides/PUBLISHING-READINESS.md`](docs/test-guides/PUBLISHING-READINESS.md).

## License

Proprietary — © 2026 OSRA. All rights reserved. No license is granted by this repository;
contact the maintainers before reusing any part of it.
