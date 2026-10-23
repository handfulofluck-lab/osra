# API QA — services/api

QA pass against `docs/SPEC.md` §3, §12, §14. Suite: `pnpm vitest run` (vitest + `vi.mock("../src/db.js")` + `vi.mock("ioredis")`; no live Postgres/Redis needed). Legend: ✓ = covered by an automated test; · = not applicable / no such case; (mw) = covered via the shared `requireParent`/`requireFamily` middleware tests on a sibling route (same code path).

## Endpoint matrix

### `/v1/auth` (auth.ts)

| Endpoint | happy | 400 | 401/403 | 404 | notes |
|---|---|---|---|---|---|
| POST /register | ✓ 201 | ✓ short pw, bad email, bad region | · | · | 409 email_taken ✓; tx family+parent ✓ |
| POST /login | ✓ 200 | ✓ malformed body | ✓ 401 wrong pw + unknown email | · | argon2 verify |
| POST /mfa/enroll | ✓ 200 | · | ✓ 401 no JWT | · | stores base32 secret, otpauth URL |
| POST /mfa/verify | ✓ 200 | ✓ bad code shape, not enrolled | ✓ 401 no JWT / wrong code / **expired code** | · | ±1 step TOTP window |
| POST /reset/request | ✓ 200 (always) | ✓ bad email | · | · | no account enumeration (200 for unknown email ✓) |
| POST /reset/confirm | ✓ 200 | ✓ short pw | ✓ 401 garbage token + **login JWT rejected (purpose-scoped)** | · | argon2 hash stored ✓ |
| POST /token/refresh | ✓ 200 | ✓ missing body | ✓ 401 unknown token + **replay after rotation** | · | rotation invalidates consumed token ✓ |

### `/v1/family` (family.ts)

| Endpoint | happy | 400 | 401/403 | 404 | notes |
|---|---|---|---|---|---|
| GET /me | ✓ 200 | · | ✓ 401 no JWT, 403 device | ✓ family gone | strips passwordHash/mfaSecret ✓ |
| POST /children | ✓ 201 inline consent | ✓ missing name, future birthYear, bad consent method | ✓ 401 (mw), 403 device | ✓ family gone | 428 no-consent gate ✓, 428 jurisdiction mismatch ✓ |
| GET /children/:id | ✓ 200 | · | ✓ 401, 403 foreign | ✓ | |
| PATCH /children/:id | ✓ 200 | ✓ empty name, year 1899 | (mw) | ✓ | |
| DELETE /children/:id | ✓ 200 GDPR cascade (7 deletes in one tx) | · | (mw) | (mw) | |
| POST /children/:id/consent | ✓ 201 | ✓ bad method | (mw) | (mw) | **428 jurisdiction mismatch (bug #5 fix)** |
| GET /export | ✓ 200 JSON attachment | · | (mw) | ✓ | **parents sanitized (bug #1 fix)**; Content-Disposition ✓ |

### `/v1/devices` (devices.ts)

| Endpoint | happy | 400 | 401/403 | 404 | notes |
|---|---|---|---|---|---|
| POST /register | ✓ 201 | ✓ bad platform, missing fields | ✓ 403 device token | · | foreign **and** missing child → 403 (no enumeration) ✓ |
| POST /pair | ✓ 201 (6-digit, 600 s TTL, SET NX) | ✓ empty body | ✓ 403 device token, 403 foreign child | · | Redis `pair:<code>` payload verified |
| POST /pair/claim | ✓ 201 ×2 (device JWT claims, model fallback) | ✓ bad code shape, bad platform, missing fields | · (public by design) | ✓ unknown/expired + consumed-code replay | client-supplied ids ignored ✓ |
| GET / | ✓ 200 family-scoped where | · | ✓ 401 no token | · | |
| GET /:id | ✓ 200 telemetry merged from Redis | · | (mw) | ✓ | |
| POST /:id/command | ✓ 200 publish + queue | ✓ unknown command | ✓ 403 foreign | (mw) | `{type, payload}` shape ✓ |
| GET /:id/commands | ✓ 200 drains queue | · | (mw) | (mw) | |
| POST /:id/push-token | ✓ 204 (device JWT) | ✓ token under 20 or over 4096 characters | ✓ 403 parent (owner or co-parent, `device_role_required`) · ✓ 403 sibling device (`forbidden`) | (mw) | device-only since #319 — body `{token}`, one token per device |
| POST /:id/telemetry | ✓ 202 (device JWT) | ✓ battery 150 / −1 / string, bad appUsage, bad urls | ✓ 403 foreign device | (mw) | refreshes lastSeen/status |
| DELETE /:id | ✓ 200 | · | ✓ 403 device token | ✓ | |

### `/v1/rules` (rules.ts)

| Endpoint | happy | 400 | 401/403 | 404 | notes |
|---|---|---|---|---|---|
| GET /:childId | ✓ 200 stored row + defaults when none (device JWT ok) | · | ✓ 403 foreign | ✓ | flat→nested mapping asserted |
| PUT /:childId | ✓ 200 upsert + Redis publish + device fanout | ✓ invalid payload, window overlap, **impossible times (bug #4 fix)** | ✓ 401 no JWT, 403 device | (mw) | allowOverlap opt-out ✓ |
| PATCH /:childId | ✓ 200 deep-merge; **patch on allowOverlap ruleset (bug #6 fix)** | ✓ invalid body, window-overlap change | (mw) | (mw) | overlap guard only when windows touched |

### `/v1/alerts` (alerts.ts)

| Endpoint | happy | 400 | 401/403 | 404 | notes |
|---|---|---|---|---|---|
| GET / | ✓ 200 envelope, defaults 1/20, skip math (p3 → skip 40), filters | ✓ page=0/−2/abc, limit=0/101/many, bad severity **(bug #2 fix — was 500)** | ✓ 401 no JWT, 403 device | · | limit hard cap 100 (schema max) |
| POST /:id/ack | ✓ 200 | · | ✓ 403 foreign | ✓ | |
| POST /internal | ✓ 201 persist → publishFamilyEvent → push stub | ✓ invalid payload (signed) | ✓ 401 bad/missing HMAC | ✓ unknown child | timing-safe HMAC compare |

### `/v1/location` (location.ts)

| Endpoint | happy | 400 | 401/403 | 404 | notes |
|---|---|---|---|---|---|
| POST /ping | ✓ 201 parent JWT, device JWT, **HMAC-only**; boundary ±90/±180 | ✓ lat/lng out of range, string lat, negative accuracy, missing childId | ✓ 401 no creds / bad HMAC; ✓ 403 wrong-family JWT | ✓ unknown child | geofence enter/exit/no-transition ✓ (existing) |
| GET /:childId/latest | ✓ 200 newest first | · | ✓ 403 foreign | ✓ no_pings | |
| GET /:childId/history | ✓ 200 from/to window (gte/lte asserted), no-window case | ✓ malformed from/to **(bug #3 fix — was 500)** | (mw) | (mw) | take: 500 cap asserted |
| GET /geofences/:childId | ✓ 200 | · | (mw) | (mw) | |
| POST /geofences | ✓ 201 | ✓ radius 5 / 100001 / lat 91; missing childId | ✓ 403 foreign child | (mw) | |
| DELETE /geofences/:id | ✓ 200 | · | ✓ 403 device token, 403 foreign | ✓ | |

### Server plugins (server.ts parity, security.test.ts)

| Check | result |
|---|---|
| Rate limit 200 req/min | ✓ requests 1–200 → 200, request 201 → 429 (fast: `app.inject`, no network) |
| CORS `origin: true, credentials: true` | ✓ preflight OPTIONS 204 reflects `access-control-allow-origin` + `allow-credentials: true`; simple GET also reflects |

## Bugs found & fixed

1. **HIGH — `GET /v1/family/export` leaked credential material.** The export included raw `parents` rows (`passwordHash`, `mfaSecret`) while `GET /me` sanitized them. GDPR exports are downloaded and stored outside the API, so this spread password hashes and TOTP secrets. Fix (`family.ts`): hoisted the sanitizer to module scope (`sanitizeParent`) and applied it to export parents. Regression: `family.test.ts` “GET /export downloads the family archive without credential material”.
2. **MEDIUM — `GET /v1/alerts` returned 500 on invalid query params.** `ListQuerySchema.parse()` threw on `page=0`, `limit=101`, `limit=abc`, `severity=bogus` → unhandled ZodError → 500. Fix (`alerts.ts`): `safeParse` → 400 with the flattened error. Regression: “rejects out-of-range pagination and unknown enum filters with 400 (not 500)”.
3. **MEDIUM — `GET /v1/location/:childId/history` returned 500 on malformed `from`/`to`.** Same parse-throw pattern. Fix (`location.ts`): `safeParse` → 400. Regression: “rejects malformed from/to datetimes with 400 (not 500)”.
4. **MEDIUM — rules accepted impossible clock times.** The `HHMM` regex `/^\d{2}:\d{2}$/` passed `25:00`, `21:99`, `24:00` for bedtime/school/routine windows; nonsense would be persisted and pushed to every child device. Fix (`rules.ts`): `/^([01]\d|2[0-3]):[0-5]\d$/`. Regression: “rejects impossible clock times in rule windows (400)”.
5. **MEDIUM — `POST /v1/family/children/:id/consent` accepted any jurisdiction.** The inline create-child path rejects a jurisdiction that differs from the family region (428), but this endpoint recorded ConsentRecords that can never satisfy the §12.5 gate. Fix (`family.ts`): family lookup + 428 `consent_jurisdiction_mismatch`. Regression: “rejects consent whose jurisdiction does not match the family region (428)”.
6. **LOW — `PATCH /v1/rules/:childId` rejected unrelated patches on `allowOverlap` rulesets.** `allowOverlap` is input-only (never persisted), so the overlap guard re-ran against merged windows on every patch: a ruleset created with `allowOverlap: true` could never be patched again without re-passing the flag. Fix (`rules.ts`): run the guard only when the patch touches `bedtimeStart`/`bedtimeEnd`/`schoolHours`. Regressions: “allows a PATCH that does not touch windows on an allowOverlap ruleset (200)” + “still rejects a PATCH that changes windows into an overlap (400)”.

## Known non-blocking gaps

1. **Access tokens never expire** (login/register/refresh sign without `expiresIn`), which makes refresh rotation moot against token theft. Recommend a short TTL (e.g. `1h`). Not changed here: altering session semantics is a product decision; no in-repo consumer relies on non-expiry. (medium)
2. **MFA is not enforced at login.** `mfaEnabled` is set by `/mfa/verify` but `/login` never requires a TOTP second factor. Spec §3 defines only enroll/verify and §12.7 forbids new features, so this is documented, not “fixed”. (medium)
3. **`GET /v1/alerts` has no `acknowledged` filter** although the parent app (spec §7) and `scripts/e2e.mjs` call `?ack=false`; zod strips the unknown param, so unacknowledged-only views silently get all alerts. §3 specifies only childId/severity/category filters. (low-medium)
4. **Password reset does not invalidate outstanding sessions/refresh tokens** for the parent (the in-memory refresh store is already flagged for Redis persistence in a code NOTE). (low)
5. **Non-atomic Redis sequences, accepted by design:** pair claim GET-then-DEL (spec §14.1 allows the race; code NOTE), and `GET /:id/commands` lrange-then-del can drop a command pushed mid-drain. (low)
6. **Missing child on `/devices/register` and `/devices/pair` returns 403, not 404** — deliberate no-enumeration; tested as-is. (info)
7. **`POST /location/ping` with an unknown `deviceId` would 500 on the DB FK** in production (ping row + alert rows reference `Device`); the agent contract guarantees paired device ids and the `lastSeen` refresh is already best-effort. (low)
8. **Geofence transition evaluation is read-then-write without locking** — two concurrent pings can both raise the same enter/exit alert. Needs a lock/serializable tx to fully close. (low)
9. **Emails are case-sensitive** at register/login (`A@x.com` ≠ `a@x.com` → duplicate accounts possible). (low)
10. **Rate limit is global (200/min/instance, in-memory), not per-route** — no stricter cap on `/v1/auth/*` beyond argon2 cost. Candidate hardening. (low)

## Verification

- `pnpm vitest run` — **112/112 green** (8 files), up from 44 → 112 (+68). Per file: auth 5→14, family 8→20, devices 3→15, rules 6→13, alerts 4→12, geofence 6→23, pairing 12→13, security 0→2.
- `pnpm build` (`tsc`) — clean.
