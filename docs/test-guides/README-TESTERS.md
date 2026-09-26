# OSRA — Test Release (Android + Windows)

> **Repo note:** built binaries (`OSRA-Parent.apk`, `OSRA-ChildAgent.apk`,
> `OSRA-Agent-Windows/`) are distributed with test bundles / GitHub Releases —
> they are not committed to this repository. This guide describes that bundle.

> **Branding note (2026-09-17):** the product was renamed from *FamilyShield* to **OSRA (أسرة — "family")**.
> Technical identifiers stay unchanged so already-paired devices keep working: Android package id
> `com.familyshield.agent`, the `X-FamilyShield-Signature` header, `familyshield.dev` emails/URLs,
> and on-device storage paths. Artifacts: `OSRA-Parent.apk`, `OSRA-ChildAgent.apk`, `OSRA-Agent-Windows\`.

This package contains tester-installable builds of the OSRA MVP.
**iOS is intentionally not part of this release.**

> ⚠️ Test build: plain HTTP, dev secrets, debug-signed APKs, no push notifications
> (agents poll the server over HTTP instead — commands/rules can take up to ~60 s
> to reach a device). Do not use with real children's data.

## What's included

| File | What it is |
|---|---|
| `OSRA-Parent.apk` | Parent dashboard app (Android). Manage children, rules, alerts, map; generate pairing codes. Rebuilt 2026-09-18. |
| `OSRA-ChildAgent.apk` | Child device agent (Android). App/screen-time enforcement via the accessibility service, location pings, web-filter categories sync. Rebuilt 2026-09-19 — test builds allow plain HTTP to LAN dev servers (`network_security_config`), so `http://192.168.x.x:3000` pairing works. |
| `OSRA-Agent-Windows/` | Windows child-agent (self-contained, no .NET install needed). Web-filter proxy, app/process blocking, screen-time + bedtime enforcement. Includes `reset-proxy.bat` (clears the system proxy if the agent was force-killed). |
| `start-backend.bat` | One-click backend launcher for the host PC (starts Redis + Postgres + API, seeds demo data). Contains three secrets — change all three before going online (see guide step 1). |

## 1. Host the backend (owner's PC)

1. Run `start-backend.bat`. It starts everything and prints candidate LAN addresses
   (e.g. `http://192.168.1.20:3000`). PostgreSQL runs as the auto-start Windows
   service `OSRA-Postgres` (2026-09-19 — no longer tied to an open window).
2. Allow inbound TCP **3000** in Windows Firewall (or disable the firewall on the
   test network).
3. **Remote testers (different network):** expose the API with a tunnel instead,
   e.g. `cloudflared tunnel --url http://localhost:3000`, and share the https URL.
4. Demo login: `demo@familyshield.dev` / `CorrectHorseBatteryStaple!`
   (seeded family with child "Alex"). MFA/2FA is **optional and off by default** —
   leave the "Authentication code" field blank.
5. If apps error while `http://localhost:3000/health` looks fine, check
   `http://localhost:3000/health/deep` — it names the stopped dependency
   (`db`/`redis`).

## 2. Install the parent app (parent's Android phone)

1. Copy `OSRA-Parent.apk` to the phone and install (allow "install from
   unknown sources" when prompted).
2. On the login screen, set **Server** to your backend address from step 1.
   *(2026-09-19: the Server field now starts **blank** on first install — every
   app asks for the address instead of pre-showing an old or built-in one.)*
3. Sign in with the demo credentials (or register a new family).

## 3. Pair a child Android device

1. In the parent app open the child's page → **Pair a device** → a 6-digit code
   appears (valid 10 minutes).
2. Install `OSRA-ChildAgent.apk` on the child's phone, open it, enter the
   backend **Server URL** + the code, tap **Pair this device**.
3. Follow the on-screen step: enable the **OSRA** accessibility service
   (Settings → Accessibility). Enforcement starts immediately.
4. The device shows up in the parent app (child page / dashboard) within a minute.

## 4. Pair a Windows PC

1. In the parent app, generate a pairing code for the child (same as step 3).
2. Copy the `OSRA-Agent-Windows` folder to the child's PC and run
   `OSRA.Agent.exe`. On first run a pairing window asks for the **server
   URL** and the **code**.
3. The agent then runs in the background (system tray/console): local web-filter
   proxy on `127.0.0.1:8877`, process blocking per rules, screen-time limits,
   bedtime lock. It auto-starts via the host (run it from shell:startup for
   persistence).
4. Screen-time lock overlay unlock PIN defaults to `0000` (set env
   `DESKTOP_PARENT_PIN` to change).

## What works in this release

- Parent: login/register, child management (consent-gated), device list, rule
  editor (screen time / web filter / apps / routines), alerts with ack, live map
  with geofences, device commands (ring/lock), WebSocket live updates.
- Android agent: app blocking + time limits (accessibility), bedtime/school
  windows, routines, location pings (adaptive), telemetry, command polling.
- Windows agent: web filter + SafeSearch rewrite, app/process blocking,
  screen-time overlay, bedtime workstation lock, rules/command sync, telemetry.
- Backend: pairing, per-family data isolation (403), consent gate (428), per-device HMAC
  agent endpoints, geofence alerts, GDPR export/erasure, optional MFA (TOTP) enforced
  only when a parent enables it, refresh-token rotation with reuse detection,
  `/logout` + `/logout-all`, device-token revocation on unpair, WebSocket single-use
  tickets, deep health probe (`/health/deep` reports db/redis).

## 🆕 World-class additions (2026-09-16)

Recommended 13-category protection ON by default · blocklist pack synced to agents ·
HTTPS filtering on Windows (opt-in — see SHIP-NOTES.md) · pause internet one-tap ·
WhatsApp/social AI monitoring with encrypted snippet vault (Social tab) · calls & SMS
timeline · contact allowlist · install alerts with one-tap block · always-allowed apps ·
bonus time (+15/30/60) · wind-down · child SOS (phone quick-tile / PC Shift+F11) ·
multi-parent invites (Family members screen) · tamper & VPN alerts · reports with
usage charts · wellbeing score · live activity chip · app insights · digest prefs with
in-app preview · conversation coach cards in English and العربية.
Details: `SHIP-NOTES.md` + `WORLD-CLASS-CHANGELOG.md`.

## Known limitations (test build)

- No push notifications — agents poll every 60 s (commands) / 60 min (rules;
  immediate after pairing and on the 6 h schedule).
- HTTPS not terminated at the API — use a tunnel with HTTPS for remote testers.
- Location tracking requires the phone's location permission granted at pairing.
  **Emulators can't verify location** (GPS injection never reaches the agent) — use a
  physical phone for map/geofence testing.
- Unpairing a device revokes its credentials immediately — the agent must be
  re-paired (fresh code) to come back online.
- iOS agent: not built (the pairing flow + agent sources are written in
  `apps/child-ios`, but compiling needs a Mac with Xcode — not in this release).
