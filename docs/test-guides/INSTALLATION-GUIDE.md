# OSRA — Online Test Installation Guide

*Revised 2026-09-19 — matches the current `dist\` artifacts (child APK rebuilt 2026-09-19).*

This guide sets up a **complete, internet-facing test environment**: the backend runs on
the host (owner) PC and is exposed through a secure tunnel, so testers can install and
use the Android and Windows apps from **anywhere** — no LAN, no router configuration.

> ⚠️ Test build notice: debug-signed APKs, dev-grade hardening, no push notifications
> (agents poll the server over HTTP: commands/rules reach devices within ~60 s).
> Use test accounts only. See *Security* at the end.

---

## 0. What you need

> 🆕 **This release (2026-09-16, "world-class") adds:** recommended 13-category web/app
> protection ON by default, pause-internet one-tap, WhatsApp/social AI monitoring with an
> encrypted snippet vault, calls & texts timeline, install alerts with one-tap block,
> bonus time, wind-down, child SOS, multi-parent invites, tamper & VPN alerts, reports
> with charts, wellbeing score, live activity chip, and EN/عربية conversation coach cards.
> See `SHIP-NOTES.md` for the full per-feature test recipes and `WORLD-CLASS-CHANGELOG.md`
> for details. The steps below are unchanged — new features appear inside the apps.

| # | Item | Notes |
|---|---|---|
| 1 | Host PC (Windows) | Always-on during the test; internet access; the portable toolchain at `C:\KARIM\tools` (already installed). |
| 2 | This `dist` folder | Contains both APKs, the Windows agent, launcher + guide. |
| 3 | Parent Android phone | Any Android 8+ (API 26+). |
| 4 | Child Android phone | Android 8+; physical access to enable the accessibility service. |
| 5 | Child Windows PC | Windows 10/11, admin rights to set the system proxy / kill processes. |
| 6 | Tunnel tool | `cloudflared` (free, recommended; ~1 option below) or ngrok. |

Topology:

```
Parent phone ─┐
Child phone ──┼── HTTPS ──▶ Cloudflare tunnel ──▶ Host PC :3000 (API)
Child PC ─────┘                                              │
                                              Postgres :5432 ┴ Redis :6379
```

---

## 1. Start the backend on the host PC

1. On the host PC, open `start-backend.bat` in a text editor and **change the three
   secrets** before going online (any long random strings):
   ```
   set JWT_SECRET=....................
   set INTERNAL_HMAC_SECRET=..........
   set VAULT_KEY=......................
   ```
   (`VAULT_KEY` encrypts the social-monitoring snippet vault — base64, ~44 chars.)
2. Double-click `start-backend.bat`. It starts Redis, PostgreSQL (first run initializes
   it), applies migrations, seeds demo data, and starts the API on port 3000.
3. Leave this window open. Verify locally: browse to `http://localhost:3000/health` —
   you should see `{"ok":true,"version":"0.1.0"}`. If the apps ever error while
   `/health` looks fine, check `http://localhost:3000/health/deep` — it reports
   `db`/`redis` up-or-down, and a `503` there means the database or cache stopped
   (restart the backend; Postgres runs as the `OSRA-Postgres` Windows service).

## 2. Put the backend online (HTTPS tunnel)

Pick one. **No firewall or router changes are needed** — the tunnel is outbound-only.

### Option A — Cloudflare quick tunnel (free, no account, 5 minutes)

1. Download `cloudflared` for Windows:
   https://github.com/cloudflare/cloudflared/releases/latest → `cloudflared-windows-amd64.exe`
2. Run in a new command window (keep it open):
   ```
   cloudflared.exe tunnel --url http://localhost:3000
   ```
3. Within seconds it prints a public URL:
   ```
   https://acm-julian-manitoba-engaged.trycloudflare.com
   ```
   **This is your Server URL.** It is randomly generated and changes every time the
   tunnel restarts — fine for a same-day test; use Option B for multi-day tests.

### Option B — Stable URL (multi-day test)

- **ngrok** (free account gives one static domain):
  `ngrok http --url=YOUR-STATIC-DOMAIN.ngrok-free.app 3000`
- **Cloudflare named tunnel** (free Cloudflare account + any domain you own):
  `cloudflared tunnel create familyshield` → route a hostname → run as a service.

## 3. Verify the public URL

From **any** device (e.g. the parent's phone browser):

```
https://<your-tunnel-url>/health   →   {"ok":true,"version":"0.1.0"}
```

If this loads, every app below will work. If not, see *Troubleshooting*.

## 4. Install the parent app (parent's Android phone)

1. Copy `OSRA-Parent.apk` to the phone (USB, Drive, WhatsApp...).
2. Tap it → allow **Install from unknown sources** when prompted → Install.
3. Open **OSRA**:
   - **Server**: `https://<your-tunnel-url>` (the field is above the email box; it is
     saved for future launches).
   - Sign in with the demo account **demo@familyshield.dev /
     CorrectHorseBatteryStaple!** (seeded family with child "Alex"), or tap
     *Create account* to register a fresh family (choose region US/EU/UK/OTHER).

You should land on the dashboard showing the seeded child, device status and battery.

## 5. Pair & install the child Android phone

1. In the parent app, open the child's page → **Pair a device** → a 6-digit code
   appears (valid 10 minutes).
2. On the child phone: install `OSRA-ChildAgent.apk` (same way as the parent
   app), open it, enter:
   - **Server URL**: `https://<your-tunnel-url>`
   - **Pairing code**: the 6 digits
   Tap **Pair this device** → success screen.
3. On the success screen tap **Open accessibility settings** → enable the
   **OSRA** service (required for app blocking). Also grant **Location**
   permission (Always allow) when asked — the foreground service notification
   "Location sharing is active" confirms it is running.
4. Back in the parent app, the device appears on the child's page within ~1 minute
   (status pill, battery).

## 6. Pair & install the Windows child PC

1. In the parent app, generate a pairing code for the child (same as step 5).
2. Copy the folder `OSRA-Agent-Windows` to the child's PC (or a USB stick).
   Double-click `OSRA.Agent.exe`.
   - *First run only*: a pairing window opens → enter **Server URL**
     (`https://<your-tunnel-url>`) and the **code** → **Pair**. The config is stored
     beside the exe in `agent.config.json`.
3. The agent now runs in the background (console window — keep it open, or use
   `shell:startup` to auto-start at logon). It provides:
   - web filter proxy on `127.0.0.1:8877` (system proxy auto-set; SafeSearch on),
   - app/process blocking and screen-time limits from the child's rules,
   - bedtime → workstation lock. Screen-time lock PIN defaults to `0000`
     (set env `DESKTOP_PARENT_PIN` to change).

## 7. Functional test checklist (what to verify)

| # | Action (parent app) | Expected result | Latency |
|---|---|---|---|
| 1 | Dashboard after login | Child card, device online, battery | — |
| 2 | Edit rules → block an app on the Android child → Save | App is blocked on the child phone (block screen) | ≤ ~60 s |
| 3 | Edit rules → bedtime window covering now → Save | Child phone blocks apps; PC locks the workstation at bedtime | ≤ ~60 s |
| 4 | Child's device → device card → **Ring** / **Lock** | Phone rings / block screen; PC shows a full-screen lock overlay that only a parent PIN (default `0000`) dismisses — **Unlock** works from the app | ≤ ~60 s |
| 5 | Open a blocked site on the child PC | "Blocked by OSRA" page; SafeSearch forced on Google/Bing/YouTube | immediate |
| 6 | Watch **Alerts** while testing | `app_blocked`, `geofence`, `screen_time_exceeded` alerts appear in real time (WebSocket) | realtime |
| 7 | Map screen | Child location updates (phone); geofences Home/School drawn (map tiles need a Google Maps API key — without one the map is blank but locations/controls still work) | ~60 s batch |
| 8 | Swipe an alert to acknowledge | Alert clears from badge | immediate |
| 9 | Alerts → tap for detail | Metadata per category + "How to talk about this" coach card (English/عربي) on concerns | — |
| 10 | Child page → **Pair a device** again | New code each time; old codes die after 10 min or first use | — |
| 11 | Child page → Rules → web filter | **Recommended protection** switch ON with 13 categories; turning it off asks to confirm | — |
| 12 | Dashboard → child card → **Internet pill** → Pause | PC/phone shows "paused"; only always-allowed apps work; pill turns red; Resume restores | ≤ ~60 s |
| 13 | Child page → Social tab → toggle WhatsApp ON, then exchange a test message on the child's phone containing the phrase "kill yourself" (test only) | Within ~1 min a `social_concern` alert; Social tab shows the concern with decrypted snippet, concern chips and the coach card | ~60 s |
| 14 | Install any app on the child phone | "New app installed" alert → open it → **Block this app** → the app stops opening within ~60 s | ~60 s |
| 15 | Child page → **+30** (Bonus time) | Snackbar confirms; the child's remaining screen time increases by 30 min | ≤ ~60 s |
| 16 | Child phone → quick-settings tile "OSRA SOS" → hold SOS 5 s | Critical SOS alert on the parent dashboard (PC: Shift+F11 with `FS_SOS_HOTKEY=1`) | immediate |
| 17 | Dashboard → overflow menu → **Family members** → Invite | Invite created; share the shown token — the invited parent registers and accepts | — |
| 18 | Child page → **Reports** / dashboard score ring / live chip | Usage bar chart + top blocked domains; wellbeing ring 0–100; "● app · Nm today" updates live | ~60 s |
| 19 | Turn off the OSRA accessibility service on the child phone (then re-enable) | `tamper` critical alert appears within ~1 min | ~60 s |
| 20 | PC: `setx FS_HTTPS_INSPECT 1` then restart the agent, accept the certificate prompt once | HTTPS versions of blocked domains now show the block page (opt-in; see SHIP-NOTES) | immediate |
| 21 | (Optional) Enable MFA on a parent account (API `POST /v1/auth/mfa/enroll` → confirm with `/mfa/verify`), then log out & back in | **MFA is OFF by default and optional.** When enabled, login with password alone returns 401 `mfa_required`; password + authenticator code succeeds. Leave the "Authentication code" field blank otherwise | — |
| 22 | Unpair a device from the parent app, then try the agent's old token (or re-pair the same device) | Unpaired agent is rejected (device token revoked at unpair); a fresh pair works normally | ≤ ~60 s |

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| Tunnel URL doesn't load | `start-backend.bat` window must stay open; check API window for errors; restart the tunnel. |
| Apps show "Internal Server Error" while `/health` is fine | The API is up but a dependency stopped. Check `http://localhost:3000/health/deep` — if it shows `"db":"down"` or 503, the database stopped: run `net start OSRA-Postgres` (it's a Windows service), then restart `start-backend.bat`. |
| Apps show "connection refused / timeout" | Server URL must be the **https:// tunnel address** (no trailing slash), typed identically in parent app and at pairing. |
| New tunnel URL after restart | Everyone re-enters the new URL once (parent app login screen; agents via Re-pair / delete `agent.config.json` on PC). |
| Code rejected at pairing | Codes expire after 10 min and are single-use — generate a fresh one. |
| Child phone not enforcing | Accessibility service not enabled (step 5.3), or the agent was force-stopped — reopen the agent app. Battery savers: exclude OSRA from battery optimization. |
| Windows PC not filtering | Agent console must be running (it sets the system proxy). Plain HTTP is filtered out of the box; **HTTPS needs the opt-in** `FS_HTTPS_INSPECT=1` (see the dedicated row above). Demo blocking by adding a domain to the child's blocked list and opening its `http://` version (e.g. `http://neverssl.com`). **Firefox:** set Settings → General → Network Settings → *Use system proxy settings*. Blocked attempts raise `web_threat` alerts in the app. |
| Unlock on PC doesn't respond | Lock is an agent overlay dismissed only by the parent PIN (default `0000`, change via `DESKTOP_PARENT_PIN`); pressing **Unlock** in the app dismisses it within ~60 s. The child cannot close it without the PIN. |
| Location not updating on map | Phone location permission must be "Always", not "While using", and GPS must be on. **Testing on an emulator?** GPS injection doesn't reach the agent reliably — verify location on a physical phone. |
| Alerts not appearing live | Parent app must be on the same Server URL; pull-to-refresh works regardless. |
| Social concerns not appearing | WhatsApp monitoring must be ON (Social tab), the child's accessibility service must be enabled, and the test phrase must come from a monitored app. Checks run on the phone's ~60 s loop — allow a minute. |
| "Paused" device can still open some apps | Those apps are in **Always allowed** (Rules → Apps) — remove them to block everything during pause. |
| HTTPS filtering not working | It is opt-in: `setx FS_HTTPS_INSPECT 1` on the child PC, restart the agent, and confirm the one-time root-certificate dialog. Some pinned apps (banking) bypass it by design. |
| Calls/texts timeline empty | Grant "Call & SMS permissions" from the agent app's completion screen (optional, runtime prompt). iOS cannot monitor calls/texts (by design). |
| Invite token rejected | Tokens expire after 7 days and are single-use; the invited parent's account email must match the invite email exactly. |

## 9. Security & cleanup for an internet-exposed test

- Change `JWT_SECRET` / `INTERNAL_HMAC_SECRET` in `start-backend.bat` before going
  online (done in step 1). Anyone who knows the tunnel URL can reach the API; the
  secrets + your passwords are the only barrier.
- The tunnel URL is unlisted but public — share it only with testers; treat it like a
  password.
- When the test day ends: close the tunnel window, then close `start-backend.bat`
  (use the **Stop** option if prompted to stop Redis/Postgres cleanly).
- Do not enroll real children's personal devices with real accounts for this test.
