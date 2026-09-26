# OSRA — Response to Code Review (2026-09-18)
**Review:** `C:\Users\admin\Documents\kimi\tasks\2026-09-18\16-07-45-484eec0e\OSRA-CODE-REVIEW-2026-09-18.md`
**Status legend:** ✅ fixed & verified · 📄 documented/deferred (with reason)

## Criticals

| # | Finding | Status |
|---|---|---|
| 3.1 | MFA never enforced at login | ✅ `/login` now requires a valid TOTP when `mfaEnabled` (+ replay protection: accepted counter stored per parent in Redis; `/mfa/verify` uses the same fresh-verify). Parent app has an optional code field. Tests: MFA-required 401, wrong code 401, correct 200, replay rejected. |
| 3.2 | Wellbeing URL mismatch | ✅ Fixed both sides: Flutter calls `/v1/reports/wellbeing/$childId`; the widget test that pinned the wrong URL corrected. Suite can no longer green-light the bug. |
| 3.3 | App Insights endpoint missing | ✅ Implemented `GET /v1/insights/apps?packageId=` with a curated 15-app DB (age ratings, risks, safer alternatives); 401/404 contract tests. Verified live (`com.discord` → full record). |
| 3.4 | iOS can't enroll → alerts dropped | 📄 Documented gap (needs Xcode/macOS). Improvements landed: `AlertReporter` now reads the base URL from the app group (`agent.apiBaseURL`, fail-loud when unset) instead of the placeholder domain. Full pairing flow remains macOS work (see `IOS-BUILD-NOTES.md`). |
| 3.5 | Hardcoded `DEV_HMAC_SECRET` in APK | ✅ Removed entirely — unpaired agents now send unsigned (server 401s = fail-closed). JVM-tested minutes clamp added alongside. |
| 3.6 | macOS agent is a placeholder | 📄 Documented scaffolding (no Mac to build on). `PairingService` now takes a `platform` parameter (`windows`/`macos`) for the future port. |
| 3.7 | Committed dev secrets / vault key | ✅ Rotated: `start-backend.bat` now carries strong random `JWT_SECRET`/`INTERNAL_HMAC_SECRET` + base64 `VAULT_KEY`; `docker-compose.yml` requires env (`${VAR:?}`); server fails fast on missing secrets in production and warns on dev values in dev. ⚠️ Testers must re-pair devices (old HMAC secret is dead by design). |

## Mediums — fixed (API)

| # | Fix |
|---|---|
| API-1 | CORS allowlist via `CORS_ORIGIN` env (reflect-with-NOTE remains the dev default) |
| API-3 | Parent access tokens now expire (7d); Flutter stores `refreshToken` and retries once via `/v1/auth/token/refresh` on 401 |
| API-4 | `publishFamilyEvent` reuses the shared lazy publisher (dedicated subscriber connection kept for psubscribe) |
| API-6 | Command drain is atomic (Lua LRANGE+DEL) |
| API-7 | Email normalized (trim+lowercase) on register/login/reset |
| API-8 | `/reset/confirm` returns 404 when the account vanished (was 500) |
| API-9 | Geofence transitions scope the previous ping to the same deviceId |
| API-10 | Push tokens stripped from `/v1/family/me` and the GDPR export |
| API-11 | Auth routes get a stricter 20/min rate-limit bucket |

## Mediums — fixed (Flutter)

Wellbeing URL + test · MFA code field · refresh-on-401 · URL regex accepts hyphenated hosts (+ tests) · Android launcher label = OSRA · cleartext network-security config for LAN testing (test-only, flagged) · dead `firebase_*` dependencies removed · WS reconnect with exponential backoff.

## Mediums — fixed (Android / iOS)

HMAC fail-closed (3.5) · minutes clamp 1–240 (JVM-tested) · iOS: shield copy → OSRA · `intervalDidStart` unions rule-blocked + bedtime tokens (clobber bug) · `RoutineWindow` handles 00:00–24:00 fully · `AlertReporter` base URL from app group.

## Mediums — fixed (Desktop)

Proxy startup failure now raises a throttled (1/h) `tamper` alert when paired (was log-only fail-open) · `PairingService` platform parameter.

## Documented / deferred (with reasons)

- **WS token in query string** (API-5): documented; one-time-ticket upgrade is production work.
- **Refresh tokens in memory + no logout** (API-2): refresh rotation works; Redis persistence + `/logout` are production items (NOTE already in code).
- **Desktop fail-open** beyond the new alert, **WinINET bypass**: documented honestly in SHIP-NOTES/QA-DESKTOP (WFP/router enforcement is the real fix).
- **Play-policy declarations** (QUERY_ALL_PACKAGES, SMS/call-log): documented in PUBLISHING-READINESS (required at store submission).
- **Android pause-internet VPN sinkhole**: documented top enforcement gap (overlay+app-blocking today).
- **iOS pairing + Xcode project, macOS scope**: documented; needs macOS/Xcode.
- **Release signing**: tracked in PUBLISHING-READINESS (keystore + AAB before Play).

## Verification after fixes

API **183/183** · Flutter **93/93** + analyze clean · Android **151/151** · Desktop **168/168** · **live E2E 44/44** against the running stack with rotated secrets + base64 vault key · insights endpoint verified live.

## Suites at a glance

574 automated tests green + 44 live E2E checks. Artifacts rebuilt: `OSRA-Parent.apk`, `OSRA-ChildAgent.apk`, `OSRA-Agent-Windows/`.

---

## Addendum (2026-09-19) — token & session hygiene (handoff items 1–8), implemented

All eight items landed (item 8 had already shipped with the review-fix rate limits):

1. ✅ Refresh tokens moved to Redis with rotation markers + **reuse detection** (a consumed token re-presented → `refresh_token_reused` + all sessions of that parent revoked). Migration-free (Redis keys).
2. ✅ `POST /v1/auth/logout` (per-token, always 200) + `POST /v1/auth/logout-all` (JWT); Flutter `logout()` revokes server-side.
3. ✅ Password reset and MFA enable revoke all sessions.
4. ✅ Unpair revokes the 10-year device JWT (`revoked:device:{id}` → 401 `device_revoked` on device routes).
5. ✅ **Per-device HMAC secrets**: `pair/claim` mints `Device.internalSecret` (migration 0007), returned once; `/internal` verification resolves the device secret from the body's `deviceId`; the global secret is ai-engine-only. Agents unchanged (same header/field).
6. ✅ WS tickets: `POST /v1/ws-ticket` (60 s, single-use) — Flutter connects with `?ticket=`; legacy `?token=` kept for old clients (deprecated).
7. ✅ TOTP replay store fails closed in production when Redis is down (loud error + rejected login).
8. ✅ (already) refresh endpoints under the 20/min auth bucket.

**Verification:** API 189/189 · Flutter 93/93 (incl. a midnight time-bomb fixture fix) · **live E2E 50/50** — new live checks: WS ticket flow, per-device-secret 201 vs global-secret 401, unpair → revoked JWT 401. Parent APK rebuilt. SPEC-ADDENDUM updated.
