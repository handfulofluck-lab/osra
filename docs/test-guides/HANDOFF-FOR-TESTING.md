# Testing Handoff — OSRA (updated 2026-09-19, post-emulator-smoke)

## Live environment (was running on this machine; recreate if sessions were reaped)
- API: `http://localhost:3000` (healthy) · tunnel example: `https://greeting-accuracy-rainbow-teenage.trycloudflare.com` (changes on every tunnel restart)
- **Postgres = Windows service `OSRA-Postgres` (auto-start, since 2026-09-19)** — immune to console/session reaping; `net start OSRA-Postgres` if stopped. Installer: `C:\KARIM\install-pg-service.bat` (elevated, one-time).
- Redis `C:\KARIM\tools\redis\redis-server.exe --port 6379` · demo login `demo@familyshield.dev` / `CorrectHorseBatteryStaple!` (MFA off by default)
- Suite state (2026-09-19, all green): API **193** · Flutter 93 · Android JVM 151 · Desktop xunit 168 · AI 18/1 skip · **live E2E 50/50**
- Run E2E with the rotated secrets: `cd services/api && INTERNAL_HMAC_SECRET=<from docs/test-guides/start-backend.example.bat> VAULT_KEY=<from docs/test-guides/start-backend.example.bat> node scripts/e2e.mjs`
- ⚠️ Secrets were rotated after the code review and live only in the local test bundle's `start-backend.bat` (never committed) — `start-backend.example.bat` here shows the format with placeholders. Devices paired before a rotation must re-pair (fail-closed HMAC by design).

## 2026-09-19 incident: "app not signing in" — root-caused & fixed
- Symptom: parent app showed `Internal Server Error` via the live tunnel while `/health` returned OK.
- Cause: `/health` never touches dependencies, so it stayed green while **PostgreSQL was wedged** — a console control event (0xC000013A) hit the manually-started PG during crash recovery; the postmaster kept the port but every connection hung → prisma P1001 → 500 on all data routes.
- Fixes: PG restarted cleanly and **registered as the auto-start service `OSRA-Postgres`**; `start-backend.bat` now uses the service; new **`GET /health/deep`** endpoint (`{ok, db, redis}`, 503 when a dependency is down) + 4 vitest cases; guides updated with a deep-health troubleshooting row. API suite 193/193 after the change.
- MFA: verified `mfaEnabled=false` on all seeded parents; documented as optional/skippable in the guides.

## 2026-09-19 change: no pre-filled server URL (all clients rebuilt)
- Requirement: the server address must be **blank on first launch** in every client — nothing pre-shown, ever.
- Parent (Flutter): `kDefaultServerUrl`/`ApiClient._base` default changed from `http://10.0.2.2:3000` to `''`; login screen hides the "Server: …" caption until a URL is saved; WS provider no-ops on empty base. New test pins the blank default.
- Child (Kotlin): pairing form server field starts empty (hint added) and is **required** — blank server shows an inline error instead of silently falling back to the old `https://api.familyshield.dev` default; `DEFAULT_SERVER` removed. (NetworkModule build-time placeholder stays — internal plumbing, never shown.)
- Windows: pairing dialog server box no longer pre-fills `http://localhost:3000` (empty validation already existed).
- iOS: `PairingView` already defaulted to `""` — no change.
- Verified on emulator: child pairing form shows empty server field with hint; suites Flutter 94/94 · Android JVM 151/151 · Desktop xunit 168/168; artifacts rebuilt into `dist\` (parent APK needed a full clean rebuild — first build reused a stale AOT snapshot).
- Known gradle flake on this box: `Unable to delete directory …build…` / AccessDenied on intermediates → `./gradlew --stop`, `rm -rf app/build/intermediates app/build/outputs/apk/release app/build/generated`, rebuild.

## On-device emulator smoke (2026-09-19) — PASSED
- AVD `osra-test` (3 GB/2 cores, headless swiftshader) boots ~3 min; **VT-x enabled in firmware, AEHD driver RUNNING** (`sc query aehd`).
- Pairing round-trip through the real child-agent UI, FGS running, accessibility bound, **bedtime enforcement observed live**, agent↔backend loop healthy over 200 s.
- Fix found during smoke: child agent lacked a cleartext `network_security_config` for LAN dev servers → added (`apps/child-android/app/src/main/res/xml/network_security_config.xml`, test-only) → `dist/OSRA-ChildAgent.apk` **rebuilt 2026-09-19 02:29**.
- **Location pings could NOT be verified on the emulator** (`geo fix` never lands; `last location=null` globally; appops show the app registered fine). Needs a physical phone — documented in README-TESTERS + INSTALLATION-GUIDE.

## Already fixed since the 2026-09-16 review — do NOT re-report
Full mapping: `dist/OSRA-REVIEW-RESPONSE-2026-09-18.md`. Highlights:
- MFA enforced at login + TOTP replay protection (fails closed in prod if Redis is down); parent tokens expire (7d) + Flutter refresh-on-401
- Wellbeing URL fixed (both sides); App Insights endpoint implemented (live, curated DB)
- DEV_HMAC_SECRET fallback removed (fail-closed); secrets rotated; boot fails fast on missing prod secrets; **per-device HMAC secrets** (claim returns `internalSecret` once; global key = ai-engine fallback only)
- Token hygiene: Redis refresh store with rotation + reuse detection (reuse = revoke all parent sessions); `/logout` + `/logout-all`; revocation on password-reset & MFA-enable; **device JWT revoked on unpair** (`revoked:device:{id}` → 401 `device_revoked`)
- **WebSocket single-use tickets** (`POST /v1/ws-ticket` → `?ticket=`; legacy `?token=` still accepted)
- Command drain atomic (Lua); geofence transitions device-scoped; push tokens stripped from me/export
- CORS env allowlist; auth routes 20/min; email normalized; reset 404 path; insights contract tests
- Flutter: WS reconnect, android label OSRA, cleartext LAN policy (test-only), firebase deps removed, URL regex hyphen fix, MFA field, scheme-less server URL accepted (matches Android)
- Android: minutes clamp 1–240 (tested); cleartext network security config (test builds)
- iOS (static, uncompiled — needs a Mac): pairing flow **written** (`PairingClient.swift`, `AgentIdentityStore.swift`, `PairingView.swift`, `OSRAAgentApp.swift` + `PairingTests.swift`), shield copy OSRA, `intervalDidStart` clobber fixed (union), `RoutineWindow` full-day 1440, `AlertReporter` base URL from app group
- Desktop: proxy-startup-failure tamper alert (throttled), `PairingService` platform param

## Known, documented gaps (still open — fair to verify they're documented, not to re-discover)
- iOS/macOS agents not compiled/built (no Mac/Xcode here) · macOS agent is scaffolding ·
  desktop fail-open beyond the tamper alert / WinINET bypass (run `reset-proxy.bat` after force-kill) ·
  Android pause-internet is overlay+app-blocking (VPN sinkhole = production path) · release builds debug-signed ·
  Play permission declarations (QUERY_ALL_PACKAGES, SMS/call-log) · HTTPS inspection opt-in only (`FS_HTTPS_INSPECT=1`) ·
  no push (60 s poll) · location unverified on a physical phone

## Artifacts (local test bundle — binaries are not committed to the repo)
`OSRA-Parent.apk` (2026-09-19 14:23 — blank-server rebuild, verified on emulator) ·
`OSRA-ChildAgent.apk` (2026-09-19 13:41 — blank-server rebuild, verified on emulator) ·
`OSRA-Agent-Windows/OSRA.Agent.exe` (2026-09-19 13:16, + `reset-proxy.bat`) ·
guides: `README-TESTERS.md`, `INSTALLATION-GUIDE.md/.html` (updated 2026-09-19)
