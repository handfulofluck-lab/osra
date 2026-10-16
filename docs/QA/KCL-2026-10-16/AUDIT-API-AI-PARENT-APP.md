# OSRA audit: backend, AI engine, parent app (read-only, evidence-based), 2026-10-16

Base: `main@fe1997c`. Scope note: `services/api/src` is ~3.3K lines; the ~10.5K figure includes tests/scripts. Unit tests mock Prisma and Redis entirely (`services/api/test/helpers.ts:59-62`), so "tests green" proves route logic, not DB behaviour.

## A) API — rating 4/10

**(1) Data model** (`services/api/prisma/schema.prisma`): Family, Parent (MFA fields inline, `mfaSecret` plaintext :29), Child, Device (pushToken, internalSecret), RuleSet (single row per child incl. appRules/routines as JSON), ActivityEvent (generic `type`+JSON payload :93), SocialEvent (vault :103), FamilyInvite, DigestPrefs, InstallRequest (table exists, **no route uses it**), LocationPing, Geofence, Alert, ConsentRecord. **Missing tables**: commands (Redis only), refresh tokens (Redis only, `auth.ts:72-76`), comms log (folded into ActivityEvent), per-app daily usage rollups, browsing history (only `url` events), digest log, push log, audit log. No `deletedAt`/retention anywhere.

**(2) Telemetry persistence**: Split-brain. `POST /devices/:id/telemetry` writes only to Redis with 24h TTL (`devices.ts:230`) and a per-child daily counter with 48h TTL (`devices.ts:238-239`); `GET /family/me` reads today's screen time from those keys (`family.ts:52-66`). History comes only from `POST /devices/:id/activity` → `ActivityEvent` (`devices.ts:265-275`), aggregated in JS over up to 90 days (`activitySummary.ts:83-90`, loads every row, no rollup). So weekly per-app reports work *only if* the agent posts `app_usage` events, and "today" and "history" can disagree. Location history is persisted (`LocationPing`) but inserted one row at a time via `Promise.all` (`location.ts:214-228`). Child erasure (`family.ts:148-158`) does **not** delete ActivityEvent, SocialEvent or InstallRequest — orphaned PII after a "GDPR erase". No retention job of any kind (grep for cron/setInterval/worker: zero hits).

**(3) Command queue**: `enqueueDeviceCommand` publishes to a Redis channel and LPUSHes to a list capped at 100 (`deviceCommands.ts:17-22`). Devices drain via `GET /devices/:id/commands` (atomic LRANGE+DEL, `devices.ts:197-205`). **No ack, no expiry, no delivery status, no idempotency key, no persistence** — a Redis restart silently drops pending locks; a parent token can drain the queue (tracked as B11, `docs/QA/ANTIGRAVITY-INBOX.md:238`). Parent UI says "reaches the device within ~1 minute" (`child_detail_screen.dart:339`) with nothing to back it. `bonusMinutesToday` is incremented but never reset — the comment "column resets daily per migration" (`controls.ts:81`) is false; migration 0003 only adds a default-0 column.

**(4) Push to parents**: None. `FcmApnsPush.sendToFamily` is `console.log` (`alerts.ts:49-53`), and it is only invoked from `/alerts/internal`; social/content/geofence alerts don't even call the stub. No firebase/apns/expo/web-push dependency in `package.json`. Parents only learn of alerts while the app is open on the WebSocket.

**(5) Email**: None. Password reset prints the token to stdout (`auth.ts:195`); invites return the accept token inline (`invites.ts:54`); digests have prefs + a render endpoint but "scheduled delivery is a production cron job" that doesn't exist (`digests.ts:64-66`). No SMTP/provider dependency.

**(6) Open security items, plainly**:
- **J2 replay**: HMAC covers only the raw body (`internalAuth.ts:23-28`) — no timestamp/nonce/path. A captured signed `/alerts/internal` or `/location/ping` can be replayed forever (QA verified duplicate alerts). Also lets an attacker who sniffed one ping keep "placing" the child at an old location.
- **J3 consent revocation**: `revokedAt`/`expiresAt` exist but nothing reads them; no revoke endpoint on main. The "428 consent gate" fires once at child creation (`family.ts:130`) and never again. Consent is also self-attested via a dropdown (`dashboard_screen.dart:399-403`) — no actual VPC verification (no card/KBA/SMS integration). PR #48 addresses part of this — see README in this folder.
- **J6 global secret**: any body without a resolvable `deviceId`/`childId` falls through to `INTERNAL_HMAC_SECRET` (`internalAuth.ts:67-70`). One leaked env var authenticates alerts/scans for *every* child in the system.
- Extras: login-issued access JWTs have no `jti` (`auth.ts:144`) so password reset/logout-all cannot revoke them for 7 days; invite accept mints a JWT with `role: "co-parent"/"guardian"` (`invites.ts:92-95`) which `requireParent` rejects (`requireFamily.ts:69`) — co-parents are locked out until they re-login; `permissions` are stored but never enforced anywhere; `VAULT_KEY` falls back to sha256(JWT_SECRET) outside production (`snippetVault.ts:9`); MFA enroll returns the secret and stores it in plaintext.

**(7) Scale/multi-tenancy**: Family isolation via `requireFamily` is consistently applied (good). Indexes only on `(childId, ts)`; no index on `Alert.acknowledged`, `Device.childId`, `Geofence.childId`. Pagination exists only on `/alerts`; reports/social/history use `take` caps (500–1000) with no cursor. Rate limit is a single in-process bucket (`server.ts:55`) — useless behind multiple instances. WebSocket gateway keeps sockets in a process-local `Map` (`gateway.ts:10`) fed by one Redis subscriber; works across instances for delivery but has no heartbeat/backpressure. Single Prisma client, no connection pooling config, no job runner.

**(8) Concern pipeline**: `/v1/social/scan` → HMAC auth → calls ai-engine with 5s timeout → **fail-open to 3 regexes** (`social.ts:31-35`) → if flagged, AES-256-GCM encrypt first 240 chars with one global key (not per-family as the spec claims, `SPEC-AI-CONCERN-ENGINE.md:§5.2`) → `SocialEvent` → Alert throttled to one per app per 10 min. Parent sees decrypted previews via `/social/events` (server decrypts — "zero-knowledge" in the spec is false), and "30-day auto-expiry" / `DELETE /v1/family/me` from the spec don't exist. Web filter blocklist is 121 domains total across 13 categories (`data/blocklists/pack.json`).

## B) AI engine — rating 2/10

`model.py` loads a DistilBERT checkpoint from `MODEL_PATH` if present (`:153-176`); otherwise regex rules. **No checkpoint exists anywhere in the repo**, docker-compose sets `MODEL_PATH=/models/distilbert-child-safety` with **no volume mount** (`docker-compose.yml:14-18`), and the test suite forces the fallback (`tests/conftest.py:8`). So in every shipped configuration this is ~12 English regexes (`model.py:27-150`) with hand-tuned weights and a saturating score→probability map (`:214`). Categories: cyberbullying, self_harm, grooming, violence, sexual_content, substance_use, hate_speech (no "predatory_language" that the spec response shows). `context` and `child_age` are accepted and ignored (`:239-241`). No Arabic/multilingual handling at all (regexes are `\b`-anchored Latin words; Arabic text scores "safe 0.98"). No fine-tuning script, no dataset, no precision/recall numbers anywhere in repo or spec. Latency/cost: trivially cheap because it's regex; if a real DistilBERT were mounted it runs on CPU torch 2.3 synchronously in a FastAPI worker with no batching. Substance rule flags the word "pills" or "drugs" in any context — false-positive rate would be severe. Against Bark/Qustodio: not comparable.

## C) Parent app — rating 4/10

Routes (`lib/app.dart:17-37`): login, dashboard, child detail, reports, rules editor, social, searches, digest prefs, alerts, map, family. Android only — no `ios/`, `web/`, `macos/` directories. Login screen has a raw "Server URL" field (`login_screen.dart:101`) — a test-build artifact.

- Dashboard: child cards with battery, screen time vs limit, wellbeing score chip, pause-internet toggle; decent.
- Child detail (831 lines): devices with ring/lock/unlock/pause buttons, bonus minutes, wind-down, pairing via 6-digit code with countdown (`:684-686`, no QR), location list, rules summary.
- Rules editor: 4 tabs (screen time sliders + bedtime/school pickers, web filter categories with "recommended" guard, app rules via manual "Add app" by package id — no installed-app list from the device, routines). Real and reasonably complete.
- Alerts: day-grouped, swipe-to-ack, paged load-more. Good.
- Social: concern list, snippet vault modal, calls/SMS timeline, contact allowlist.
- Reports: a single fl_chart BarChart of top apps (`reports_screen.dart:88`); no daily/weekly trend, no browsing history view.
- Map: real `google_maps_flutter` with markers, geofence circles, long-press-to-create dialog with radius slider — but **no `com.google.android.geo.API_KEY` in the manifest** (`android/app/src/main/AndroidManifest.xml`), so the map renders blank on a device.
- **Release build cannot reach the network**: `INTERNET` permission exists only in `debug/AndroidManifest.xml`; the main manifest omits it. Cleartext HTTP is enabled globally (`network_security_config.xml`).
- Localization: no `.arb`, no `flutter_localizations`, no RTL/`Directionality` anywhere; only the coach cards carry paired `titleAr` strings toggled inline (`coach_content.dart:5`). Everything else is hardcoded English.
- No onboarding, no MFA enrollment screen (only a "code if MFA is on" field), no password reset, no settings beyond digest prefs, no notification permission flow (no push anyway).
- Design: stock Material 3 with `colorSchemeSeed: Colors.indigo` (`app.dart:46`), no dark theme, no typography/spacing system. Empty/error states are present (46 occurrences) and WS has a reconnect timer — competent engineering, no product polish.

## Top 8 gaps ranked by "would parents pay"

1. **No push notifications to parents** — alerts only arrive while the app is open (`alerts.ts:49`). The core value proposition of a monitoring product is missing.
2. **AI concern detection is a dozen English regexes** with no model shipped, no Arabic, no evaluation (`model.py`, `docker-compose.yml:18`).
3. **Usage data isn't durably modeled**: today's screen time lives in Redis with 24–48h TTL, history depends on agents posting events, no rollups, no retention, erasure leaves orphans (`devices.ts:230-239`, `family.ts:148-158`).
4. **Parent app ships Android-only, with no iOS target**, no Maps API key, and a release manifest lacking INTERNET — it cannot be put in a store as-is.
5. **No email at all** — password reset, invites and digests are console logs or inline tokens (`auth.ts:195`, `invites.ts:54`, `digests.ts:64`).
6. **Web filter is 121 domains** with no dynamic categorisation (`data/blocklists/pack.json`); Qustodio/Family Link classify the live web.
7. **Commands are fire-and-forget** (no ack/expiry/persistence) and bonus minutes never reset (`deviceCommands.ts`, `controls.ts:81`); parents can't trust "Lock" worked.
8. **Security/compliance debt a consumer product can't carry**: replayable device signatures (J2), consent never re-checked or revocable and self-attested (J3), global-secret fallback (J6), unrevocable 7-day login JWTs, co-parent tokens rejected by `requireParent`, no real Arabic/RTL localisation for the apparent target market.

Overall: a well-structured, test-disciplined prototype (clean family scoping, refresh rotation, HMAC per device, real geofence math) that is roughly 25–35% of a Qustodio-class backend and nowhere near it on detection, notification, reporting depth, and client readiness.
