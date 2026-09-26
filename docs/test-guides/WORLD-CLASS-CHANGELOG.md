# OSRA — World-Class Changelog
**2026-09-16** — Feature #1–#29 landed per `dist/KIMI-HANDOFF-WORLD-CLASS-2026-09-16.md`.
Suites at ship time: API **178** · Android JVM **146** · Desktop xunit **161** · Flutter **89** · AI pytest 18/1 skip · live E2E **45/45** through the public tunnel.

## Phase 1 — Default protection (#1)
- 13 recommended blocked categories default-ON for every new child (pornography, gambling, drugs, violence, weapons, hate, self_harm, dating, social_media_nsfw, chat_random, proxies_vpn, warez, ai_chatbots).
- Versioned blocklist pack (`services/api/data/blocklists/pack.json`, ~10 domains + apps per category) served at `GET /v1/blocklists`; agents sync it (Windows: domains+apps enforcement; Android: app blocking via RuleEngine).
- Parent app: "Recommended protection" switch with confirm-to-disable.

## Phase 2 — Web enforcement (#3, #18, #11)
- **HTTPS filtering (Windows)**: env-gated `FS_HTTPS_INSPECT=1` — generated self-signed root CA (`%LOCALAPPDATA%\FamilyShield\rootCert.pfx`, installed to CurrentUser\Root), Titanium TLS inspection, blocked categories fail closed over TLS. Off by default (documented trust implications).
- **Pause the internet**: `pause_internet`/`resume_internet` commands + `POST /v1/controls/children/:id/pause|resume(-internet)`; Windows sinkholes at the proxy + kills non-allowed apps; Android full-screen pause overlay; dashboard "Internet" pill + per-device Pause net/Resume net buttons; status endpoint + Redis flag.

## Phase 3 — Social & messaging (#2, #6, #17, #27)
- **WhatsApp/social AI monitoring (Android)**: Accessibility capture for WhatsApp (+Business), Instagram, TikTok, Snapchat, X, Discord, Roblox, LINE → redaction (phones/emails/numbers) → `POST /v1/social/scan` → AI engine (5 s timeout, keyword fail-open) → concern events stored **AES-GCM encrypted** (alerts carry metadata only, no snippets) + throttled alerts (`social_concern` / `gaming_chat`).
- **Calls & SMS logging**: ContentObserver → Room → activity feed; calls (number/duration/direction) + SMS previews (120 chars).
- **Contact allowlist**: unknown-number alerts (1/hour) when the allowlist is non-empty.
- Parent app: Social tab (toggles, concerns with decrypted previews, allowlist editor, calls/texts timeline).

## Phase 4 — Parent insights (#4, #5, #7, #12, #28, #29)
- Activity persisted in Postgres (`ActivityEvent`); agents upload url/app_usage batches.
- **Reports screen**: top-apps bar chart, blocked domains, social/call counts, 7/30-day range.
- **Digests**: prefs (daily/weekly/push/emails) + "send test digest" rendering markdown in-app (SMTP deferred).
- **Wellbeing score** (0–100, deterministic formula) per child on the dashboard.
- **Live chip**: WS `live_activity` → "● Instagram · 12m today" on child cards.
- **App insights** bottom sheet (age rating, risks, safer alternatives); YouTube = SafeSearch + NOTE tile.

## Phase 5 — Family Link controls (#8, #9, #10, #14, #15)
- **Install approval**: PACKAGE_ADDED → throttled alert with one-tap "Block this app" from the alert detail.
- **Always-allowed apps**: survive bedtime/school/pause/routines on both agents; editor in rules.
- **Bonus time**: +15/30/60 buttons → `bonus_time` command + `bonusMinutesToday` in rules (effective limit on all agents).
- **SOS**: Android quick-settings tile (5 s pocket-dial guard) + Windows Shift+F11 hotkey (`FS_SOS_HOTKEY=1`) → critical alert.
- **Location**: history scrubber (today's route slider) + battery on the map sheet.

## Phase 6 — Hardening & family (#13, #19–#24)
- **Multi-parent invites**: owner-only create, 7-day accept tokens, role + permissions (rules/location/alerts/social), accept attaches the parent to the family; revoke.
- **Tamper alerts**: Android accessibility-disabled detection + package-replaced; Windows proxy-disabled detection (1/hour throttles).
- **VPN detection**: Android TRANSPORT_VPN + Windows tun/tap/wireguard interfaces → warning alerts.
- **Wind-down**: `POST /v1/controls/children/:id/wind-down {minutes}` → heads-up then lock on both agents.
- **School geofence auto-apply**: geofence `routineId` → entering publishes rules + `rules_updated` to devices.
- **Encrypted vault** trust copy + AES-GCM snippet storage (see Phase 3).

## Phase 7 — Platforms & polish (#25, #16, #26)
- **macOS scaffolding** `apps/agent-macos/` (net8.0-macos csproj, portable status service, build/run scripts, full porting map README) — compiles on a Mac, not on Windows.
- **iOS**: `dist/IOS-BUILD-NOTES.md` (Xcode wrapper recipe, verification checklist); agent sources hardened in prior QA.
- **Conversation coach** (#16): EN + العربية guidance cards for self-harm, grooming, cyberbullying, sexual content, violence, hate, screen time + fallbacks — on alert details and social concerns.
- **Chromebook/Kindle**: `dist/CHROMEBOOK-KINDLE-PATH.md` honest sideload paths.

## Migrations
`0003_world_class` (ActivityEvent, SocialEvent, FamilyInvite, DigestPrefs, InstallRequest, RuleSet.alwaysAllowedApps/bonusMinutesToday) · `0004_social_contacts` (socialMonitoring, contactAllowlist) · `0005_geofence_routine` · `0006_parent_permissions`.
