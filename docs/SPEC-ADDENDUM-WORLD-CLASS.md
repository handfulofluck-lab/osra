# SPEC Addendum — World-Class features (binding contract)

Extends `docs/SPEC.md`. All phase implementations MUST follow these contracts so the
components stay wired. Conventions unchanged: one-line docstrings, `// NOTE:` on simplest
interpretations, consent gate 428, requireFamily 403, HMAC agent calls, family isolation.

## Commands (device command queue, `{type, payload}`)

| type | payload | meaning |
|---|---|---|
| pause_internet / resume_internet | `{}` | sinkhole all traffic except always-allowed (Feature #11) |
| bonus_time | `{minutes: number}` | add N minutes of screen time today only (#10) |
| wind_down | `{minutes: number}` | bedtime-style soft warning then lock (#22) |
| (existing) lock/unlock/pause/resume/ring/sos_clear/rules_updated/locate_now | | unchanged |

Command enum lives in `services/api/src/routes/devices.ts` CommandSchema.

## New alert categories (POST /v1/alerts/internal, metadata-driven)

`social_concern` (#2: metadata `{app, contact, preview, concernTypes[], contextLines?}`),
`gaming_chat` (#17), `call_sms` (#6 — summary events only), `tamper` (#19),
`vpn_detected` (#20), `install_request` (#8: `{packageId, appName}`), `unknown_contact`
(#27: `{contact}`), `bonus_granted` (#10), `wind_down` (#22), `sos` (child-initiated #14).

## New/changed API surface (all under /v1, parent JWT unless noted)

- `GET /blocklists` (device JWT or parent) → `BlocklistPack` JSON (Feature #1/18). Agents
  fetch on rules sync + daily; merge into local block stores.
- `GET /reports/activity?childId&from&to&type=` → persisted `ActivityEvent[]` (#4). Agents
  POST batches to `POST /devices/:id/activity` (device JWT, shape `{events: ActivityEvent[]}`).
- `GET /insights/apps?packageId=` → `AppInsight` (#12, curated static DB in API).
- `GET /wellbeing/:childId?week=YYYY-Www` → `WellbeingScore` (#28, computed from activity).
- `POST /digests/prefs` / `GET /digests/prefs` → `DigestPrefs` (#5); a dev `POST
  /digests/send-now` renders the digest in-app (no SMTP in test build → NOTE).
- `POST /family/invites` `{email, role, permissions[]}` / `POST /family/invites/:id/accept`
  (register-or-login link flow, token in Redis `invite:<id>`) / `GET /family/invites` (#13).
- `POST /children/:id/bonus` `{minutes}` → queues `bonus_time` to the child's devices (#10).
- `GET /social/events?childId&app&severity&limit` → vault of `SocialConcernEvent` (#24,
  server-side AES-GCM with `@familyshield/crypto` + server key env `VAULT_KEY`).
- `POST /location/places/:id/routine` — bind geofence→routine auto-apply (#23: when child
  enters a place with `routineId`, agents receive `rules_updated` + the routine rules).
- Live activity: agents include `foregroundApp` + `minutesToday` in telemetry; API emits
  WS event `{type:"live_activity", payload: LiveActivity}` on `family:<id>:events` (#29).

## Persistence (migration `0003_world_class.sql`)

- `ActivityEvent` table: id uuid pk, childId, deviceId?, ts, type text, payload jsonb;
  index (childId, ts).
- `SocialEvent` table (vault): id uuid pk, childId, app, contact, severity, previewCipher
  text, concernTypes text[], createdAt; index (childId, createdAt).
- `FamilyInvite` table: id, familyId, email, role, permissions text[], status, createdAt.
- `DigestPrefs` table: familyId pk, dailyEmail, weeklyEmail, pushEnabled, emails text[].
- RuleSet gains `alwaysAllowedApps text[]` (#9) and `bonusMinutesToday int` (reset daily).

## Agent behaviors
- **Windows**: blocklists merge into `blocklist_domains`(+`blocklist_apps` new table);
  pause_internet = local sinkhole (proxy returns block page for everything not in
  always-allowed); HTTPS inspection behind env `FS_HTTPS_INSPECT=1` with a generated root
  cert installed to the user store (Feature #3; documented risk); wind_down shows overlay
  after N min; SOS = Shift+F11 hotkey; tamper/VPN detection = proxy-disabled check +
  known-VPN process names.
- **Android**: blocklist apps auto-added as blocked AppRules; social capture via
  Accessibility for WhatsApp/Instagram/TikTok/Snapchat/X/LINE text nodes → redact →
  ai-engine → HMAC alert; calls/SMS via default dialer-role request (declined → log-only
  NOTE) + READ_CALL_LOG/READ_SMS; pause_internet = overlay + network callback sinkhole
  (VPNService is the production path — document); always-allowed beats bedtime/school/
  routines/pause; SOS = quick-settings tile; install approval via PACKAGE_ADDED broadcast;
  tamper = accessibility-service-disabled + package-replaced receivers.
- **Parent app**: screens per feature; dashboard live chip listens to `live_activity` WS.

## Default protection (Feature #1)

`DEFAULT_BLOCKED_CATEGORIES` from `@familyshield/shared-types` (already exported) is the
single source of truth; API `DEFAULT_RULESET`, seed, and both agents consume it.
Blocklist pack lives at `services/api/data/blocklists/pack.json` (versioned; agents GET it).

## Token & session hygiene (2026-09-19, handoff items 1–8)

- **Refresh tokens live in Redis** (`refresh:{sha256(token)}` → `{parentId, expiresAt}`, 30 d TTL;
  per-parent index set `refresh:index:{parentId}`). Rotation marks consumed tokens
  (`refresh:used:{hash}` + `refresh:owner:{hash}`); presenting a consumed token returns
  `refresh_token_reused` AND revokes every session of that parent (theft response).
- `POST /v1/auth/logout` `{refreshToken}` (always 200) revokes one; `POST /v1/auth/logout-all`
  (JWT) revokes all. Password reset and MFA enable revoke all sessions.
- Parent access JWTs expire in 7 days; the Flutter client stores `refreshToken` (secure storage
  key `refresh`) and retries once via `/v1/auth/token/refresh` on 401.
- **Device JWTs**: unpair (`DELETE /v1/devices/:id`) sets `revoked:device:{deviceId}`; a
  device-route preHandler rejects revoked device tokens with 401 `device_revoked`.
- **Per-device HMAC**: `pair/claim` mints `Device.internalSecret` (random 32 bytes hex),
  returns it once as `hmacSecret`, and `/internal` signatures are verified against the DEVICE
  secret when the body carries a `deviceId`; the global `INTERNAL_HMAC_SECRET` remains only
  for the ai-engine. Agents are unchanged (same header, same claim-response field).
- **WS tickets**: `POST /v1/ws-ticket` (JWT) returns a 60-second single-use ticket and the WS
  endpoint accepts `?ticket=` only; a request carrying the legacy `?token=<jwt>` parameter is refused
  with `401 { "error": "ticket_required" }` (issue #120).
- TOTP replay protection fails closed (rejects the login) when Redis is unreachable in
  production; it logs loudly and warns in dev.
- Auth routes (register/login/reset/mfa/refresh/logout) share a stricter 20 req/min bucket.
