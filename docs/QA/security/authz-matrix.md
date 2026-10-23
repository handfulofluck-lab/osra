# API authorization matrix (plan 2.7)

**Status: skeleton for review.** This version lists every route with the status the code says each caller
should get, read from the guards at the cited lines. It does **not** yet show observed statuses or the
probe/test coverage for each cell. Those come next, once the shape of this table is agreed (issue #326).

- **Author:** Ahmed (security + testing).
- **Read from:** `main@bbda837`. Every route line and every cited line in a route row was re-checked against `main@7b8e404`, after #331 merged.
- **Scope:** the API only (`services/api`). Device HMAC routes are in their own table, because their callers
  are signing keys, not JWTs.

## How to read a cell

The matrix has one row per route, as registered (prefix from `services/api/src/server.ts:93-114`, plus the
two realtime routes from `src/realtime/gateway.ts`). It has one column per caller.

| Code | Meaning | Where it comes from |
|---|---|---|
| `200` / `201` / `202` / `204` | allowed, with the route's success status | the handler |
| `403p:<perm>` | `403 permission_required`, **unless** the invite granted `<perm>`, then the success status | `requirePermission`, `middleware/requireFamily.ts:143-153` |
| `403o` | `403 owner_role_required` | `requireOwner`, `requireFamily.ts:127-136` |
| `403r` | `403 parent_role_required` (a device token on a parent route) | `requireParent`, `requireFamily.ts:98-101` |
| `403f` | `403 forbidden`: the resource is in another family, or a device that isn't the caller | `requireFamily.ts:221-224`, `requireOwnDevice` `:245-254` |
| `403c` | `403 cross_child_forbidden`: a device token reading another child | `requireFamily.ts:225-231` |
| `403d` | `403 device_role_required` (a parent token on a device-only route) | `routes/devices.ts:207-212`, `:461`; `routes/location.ts:75-78` (`pingAuth`, since #331) |
| `401` | `401 unauthorized` | JWT verify failure, or `isBearerSession` false (`lib/sessions.ts`) |
| `401dr` | `401 device_revoked` | the global hook, `server.ts:70-87`, plus `devices.ts:647-657` |
| `401s` | `401 session_revoked`: a parent token after `logout-all`, a password reset, an MFA change, an invite move, or the refresh-reuse theft response | the global hook, `server.ts:84-86` (it runs before every route's own preHandlers); `isParentSessionLive`, `lib/sessions.ts:123-145` |
| `428` | consent gate: `428` while the child's consent is withdrawn or missing | `middleware/requireConsent.ts`, or `assertProcessingAllowed` inside the handler |
| `own` | the route reads only the caller's own family or parent, so there's no "other family" target to test | the handler's `where` clause |
| `—` | doesn't apply to this route |  |

### Callers (columns)

| Column | Who | How the token is minted |
|---|---|---|
| **Owner** | the parent who created the family (`Parent.role = owner`) | `/v1/auth/register` or `/login` |
| **Co-parent** | invited parent, `role = co-parent`, with the permissions on the invite | invite accept |
| **Guardian** | invited adult, `role = guardian`, with the permissions on the invite | invite accept |
| **Other fam.** | an owner of a **different** family, aiming at this family's resource id | `/register` |
| **Own dev.** | the paired device whose id or child the route names | `/v1/devices/pair/claim` |
| **Sib. dev.** | another paired device in the **same** family (a sibling's phone) | `/pair/claim` |
| **Revoked** | a device token whose device was unpaired (`DELETE /v1/devices/:id`) | — |
| **Revoked session** | a parent access token (any family role) after its session was revoked. Parent tokens live 7 days (`lib/sessions.ts:24`), so this column is what holds after a theft | `logout-all`, password reset, MFA enable, invite accept, refresh reuse |
| **Expired** | any JWT past `exp` | — |
| **Wrong purpose** | a signed JWT with a `purpose` claim: `password_reset`, `mfa_recovery`, `mfa_reset_confirm`, `mfa_reset_cancel` | `/reset/request`, `/mfa/recover`, `/mfa/reset/request` |
| **None** | no `Authorization` header | — |

The JWT `role` is `parent` for owner, co-parent and guardian (`lib/sessions.ts`, `signParentToken`). They
differ only by the `Parent` row's `role` and `permissions`, which `requireOwner` and `requirePermission`
read. So the co-parent and guardian columns show the same codes unless a route names a role.

## 1. JWT routes

### `/v1/alerts` (`routes/alerts.ts`)

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `GET /v1/alerts` | 58 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/alerts/:id/ack` | 81 | 200 | 403p:alerts | 403p:alerts | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

### `/v1/devices` (`routes/devices.ts`)

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `POST /v1/devices/register` | 234 | 201 | 403p:devices | 403p:devices | 403f (child check, `:242`) | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 (`:245`) |
| `POST /v1/devices/pair` | 262 | 201 | 403p:devices | 403p:devices | 403f (`:270`) | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 (`:273`) |
| `POST /v1/devices/pair/claim` | 285 | — | — | — | — | — | — | — | — | — | — | 201 with a live code, else 404 | 428 (`:298`) |
| `GET /v1/devices` | 332 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/devices/:id` | 345 | 200 | 200 | 200 | 403f | 200 | 403f (`:348`) | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/devices/:id/apps` | 368 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/devices/:id/apps` | 398 | 403d (F2) | 403d (F2) | 403d (F2) | 403f | 202 | 403f | 401dr | 401s | 401 | 401 | 401 | 428 (`:403`) |
| `POST /v1/devices/:id/command` | 422 | 200 | 403p:devices | 403p:devices | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 except safe-direction commands (`:432`) |
| `GET /v1/devices/:id/commands` | 458 | 403d | 403d | 403d | 403f | 200 | 403f (`:462`) | 401dr | 401s | 401 | 401 | 401 | 428 (`:465`) |
| `POST /v1/devices/:id/commands/:commandId/ack` | 471 | 403f (`:474`) | 403f | 403f | 403f | 200, or 404 `no_delivered_command` | 403f | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/devices/:id/commands/history` | 483 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/devices/:id/push-token` | 512 | 403d | 403d | 403d | 403f | 204 | 403f | 401dr | 401s | 401 | 401 | 401 | none, by decision (`:507`) |
| `POST /v1/devices/:id/telemetry` | 531 | 403d (F2) | 403d (F2) | 403d (F2) | 403f | 202 | 403f | 401dr | 401s | 401 | 401 | 401 | 428 (`:537`) |
| `POST /v1/devices/:id/activity` | 577 | 403d (F2) | 403d (F2) | 403d (F2) | 403f | 202 | 403f | 401dr | 401s | 401 | 401 | 401 | 428 (`:583`) |
| `DELETE /v1/devices/:id` | 632 | 200 | 403p:devices | 403p:devices | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

### `/v1/family` (`routes/family.ts`, `routes/invites.ts`)

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `GET /v1/family/me` | family 48 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `PATCH /v1/family/me` | family 108 | 200 | 403o | 403o | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/family/children` | family 120 | 201 with inline consent, else 428 | 403o | 403o | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 (`:135`, `:164`) |
| `GET /v1/family/children/:id` | family 168 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `PATCH /v1/family/children/:id` | family 179 | 200 | 403p:rules (F3) | 403p:rules (F3) | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `DELETE /v1/family/children/:id` | family 193 | 200 | 403o | 403o | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/family/children/:id/consent` | family 199 | 201 | 403o | 403o | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/family/children/:id/consent` | family 236 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/family/children/:id/consent/revoke` | family 270 | 200 | 403o | 403o | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/family/export` | family 300 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/family/invites` | invites 33 | 201 | 403o | 403o | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/family/invites` | invites 61 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/family/invites/:id/accept` | invites 71 | 200 if the token's email matches, else 403 `email_mismatch` | same | same | same | 401 (no Parent row, `:81`) | 401 | 401dr | 401s | 401 | 401 | 401 | — |
| `DELETE /v1/family/invites/:id` | invites 115 | 200 | 403o | 403o | 403f (`:120`) | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

On the owner-only routes, the "Other fam." caller is an owner, so `requireOwner` passes and `requireFamily`
answers `403f`. A co-parent or guardian of another family would get `403o` first.

### `/v1/location` (`routes/location.ts`)

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `POST /v1/location/ping` | 187 | 403d (F4) | 403d (F4) | 403d (F4) | 403d (F4) | 201 | 403c / 403 `device_mismatch` when the body names another child or device (`:243-247`) | 401dr (`:81-84`) | 401s | 401 | 401 | 401, unless the request is HMAC-signed (§2) | 428 (`:259`) |
| `GET /v1/location/:childId/latest` | 330 | 200 | 200 | 200 | 403f | 200 | 403c | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/location/:childId/history` | 341 | 200 | 200 | 200 | 403f | 200 | 403c | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/location/geofences/:childId` | 365 | 200 | 200 | 200 | 403f | 200 | 403c | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/location/geofences` | 372 | 201 | 403p:location | 403p:location | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `DELETE /v1/location/geofences/:id` | 381 | 200 | 403p:location | 403p:location | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

"Sib. dev." here means a device of a **different child** in the same family. Two devices of the same child
are both "own child" on the child-scoped reads.

### `/v1/rules` and `/v1/controls` (`routes/rules.ts`, `routes/controls.ts`)

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `GET /v1/rules/:childId` | rules 145 | 200 | 200 | 200 | 403f | 200 | 403c | 401dr | 401s | 401 | 401 | 401 | 428 for a device only (`:150`) |
| `PUT /v1/rules/:childId` | rules 156 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `PATCH /v1/rules/:childId` | rules 174 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `POST /v1/controls/children/:childId/pause-internet` | controls 42 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `POST /v1/controls/children/:childId/pause` | controls 48 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `POST /v1/controls/children/:childId/resume-internet` | controls 61 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | exempt (safe direction) |
| `POST /v1/controls/children/:childId/resume` | controls 66 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | exempt (safe direction) |
| `POST /v1/controls/children/:childId/bonus` | controls 73 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `POST /v1/controls/children/:childId/wind-down` | controls 97 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | 428 |
| `GET /v1/controls/children/:childId/status` | controls 111 | 200 | 403p:rules | 403p:rules | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

### Reports and content reads (`routes/reports.ts`, `routes/social.ts`, `routes/content.ts`)

Every route here is `[requireParent, requireFamily(child)]`, with `childId` taken from the query string,
except `wellbeing`, which takes it from the path. None names a permission or the consent gate.

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `GET /v1/reports/activity?childId=` | reports 40 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/reports/summary?childId=` | reports 59 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/reports/usage?childId=` | reports 70 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/reports/web?childId=` | reports 83 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/reports/wellbeing/:childId` | reports 92 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/social/events?childId=` | social 166 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/content/searches?childId=` | content 264 | 200 | 200 | 200 | 403f | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

A missing `childId` is `400 missing_childId` from `requireFamily` (`:212-215`), before any data is read.

### Parent-only, per-parent (`routes/digests.ts`, `routes/me.ts`)

These read or write only rows keyed by the caller's own id, so there's no other-family target.

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `GET /v1/digests/prefs` | digests 48 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `PUT /v1/digests/prefs` | digests 54 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/digests/send-now` | digests 71 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `POST /v1/me/push-token` | me 21 | 201 | 201 | 201 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `DELETE /v1/me/push-token` | me 35 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/me/push-tokens` | me 43 | 200 | 200 | 200 | own | 403r | 403r | 401dr | 401s | 401 | 401 | 401 | — |

### Any bearer: parent or device (`routes/blocklists.ts`, `routes/insights.ts`)

`requireAuth` is role-agnostic on purpose (`requireFamily.ts:82-84`): agents read these too.

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `GET /v1/blocklists` | blocklists 12 | 200 | 200 | 200 | 200 | 200 | 200 | 401dr | 401s | 401 | 401 | 401 | — |
| `GET /v1/insights/apps?packageId=` | insights 33 | 200 / 404 | 200 / 404 | 200 / 404 | 200 / 404 | 200 / 404 | 200 / 404 | 401dr | 401s | 401 | 401 | 401 | — |

### Realtime (`src/realtime/gateway.ts`)

| Route | Line | Owner | Co-parent | Guardian | Other fam. | Own dev. | Sib. dev. | Revoked | Revoked session | Expired | Wrong purpose | None | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `POST /v1/ws-ticket` | 23 | 200 | 200 | 200 | own | 403r (`:41-42`) | 403r | 401dr (`:35-39`) | 401s | 401 | 401 (Q4) | 401 | — |
| `GET /v1/ws?ticket=` | 53 | upgrade with a live ticket; the socket is bound to the ticket's family | same | same | a ticket is single-use and maps to one family | — | — | — | — | — | — | `401 ticket_required` without a ticket, or with `?token=` (`:61-68`) | — |

### Public (`routes/health.ts`)

| Route | Line | Every caller |
|---|---|---|
| `GET /health` | 9 | 200 |
| `GET /health/deep` | 14 | 200 while the DB and Redis are up |

## 1a. Coverage of the §1 cells

How to read it: `t:<file>:<line>` is the `it(` line of a unit test in `services/api/test/`, and `p:<id>` is a
check in `services/api/scripts/qa-probe.mjs`. A cell is listed only when a test or probe check **asserts
that status for that caller on that route**. Everything else in the row is **GAP**. Lines are as at
`main@7b8e404`.

**One structural fact decides the last five columns.** The unit-test harness (`test/helpers.ts:115-125`,
`buildApp`) registers the routes without the global `preHandler` in `server.ts:70-87`. That hook is the
**only** place a revoked device is refused on most routes, and the only `sv` session check in front of
the `requireAuth` routes (`requireAuth` checks the `jti`, not the session version,
`middleware/requireFamily.ts:59-80`). So no unit test can cover a revoked-device or revoked-session cell
whose route relies on the hook. Only the probe, against a live server, can.

### The shared columns: revoked device, revoked session, expired, wrong purpose, no token

| Column | Guard | Asserted today on | Everything else |
|---|---|---|---|
| Revoked (device) | global hook `server.ts:77-82`; also `devices.ts:647-657`, `location.ts:79-86`, `gateway.ts:35-40` | `GET /v1/devices/:id` (p:G9; t:token-hygiene.test.ts:188), `GET /v1/rules/:childId` (p:G10), `POST /v1/location/ping` (p:G11, p:M5), `POST /v1/ws-ticket` (p:G12), `GET /v1/devices/:id/commands` (p:M5) | **GAP** on the other 46 JWT routes |
| Revoked session | global hook `server.ts:84-86`; also `requireParent`, `requireFamily`, `requireJwt` | `GET /v1/family/me` (p:N2, p:N3), `POST /v1/auth/logout-all` (t:sessions-and-roles.test.ts:63, :80, :104, :130, :146), `GET /v1/rules/:childId` (t:sessions-and-roles.test.ts:284) | **GAP** on the rest, including the three `requireAuth` routes where the hook is the only `sv` check |
| Expired | `@fastify/jwt` verify → 401 in every guard | none. The nearest is p:A6, a garbage JWT on `GET /v1/family/me` (signature failure, same 401 branch) | **GAP** on every route |
| Wrong purpose | `isBearerSession` in each guard (`lib/sessions.ts:79-81`) | `POST /v1/location/ping` (p:G18; t:location-auth.test.ts:29), `GET /v1/rules/:childId` (t:sessions-and-roles.test.ts:164), `GET /v1/family/me` (p:O7), `POST /v1/ws-ticket` (t:realtime.test.ts:135) | **GAP** on the rest. The auth routes are in §3 |
| None | each guard's verify → 401 | `GET /v1/alerts` (t:alerts.test.ts:462), `GET /v1/devices` (t:devices.test.ts:258), `GET /v1/family/children/:id` (t:family.test.ts:162), `GET /v1/family/me` (t:family.test.ts:223), `GET /v1/rules/:childId` and `PUT` (t:rules.test.ts:267), the three controls in t:controls.test.ts:291, `GET /v1/reports/summary` (t:reports.test.ts:120), `GET /v1/reports/activity` (t:social.test.ts:357), `GET /v1/social/events` (t:social.test.ts:249), `GET /v1/digests/prefs` (t:reports.test.ts:339), `POST /v1/digests/send-now` (t:reports.test.ts:376), `POST /v1/me/push-token`, `DELETE` (t:email.test.ts:326), `GET /v1/blocklists` (t:blocklists.test.ts:38), `GET /v1/insights/apps` (t:review-fixes.test.ts:101), `GET /v1/devices/:id/apps` (t:device-apps.test.ts:246), `GET /v1/ws` (t:realtime.test.ts:147) | **GAP** on the rest |

**Plan for these five columns:** five probe checks, one per column, each looping over every JWT route in §1.
They'd be named for 2.7 and live in a new section after `O`. Each check prints the route that broke, so a
regression names its route instead of hiding inside a count. They need `JWT_SECRET` in the probe
environment to mint expired and purpose tokens. Without it they report `target`, the way G18 does today
(`qa-probe.mjs:707`).

### Per-route cells: owner, co-parent, guardian, other family, own device, sibling device, consent

`Co`/`Gu` count as covered when the refusal (`403p`/`403o`) is asserted for that role. The "with the
permission → 2xx" half is listed separately where a test has it.

- **`GET /v1/alerts`**: Ow t:alerts.test.ts:27 · Own dev. and sibling `403r` t:alerts.test.ts:462 · GAP: Co, Gu.
- **`POST /v1/alerts/:id/ack`**: Ow t:alerts.test.ts:84 · Co with and without `alerts` t:sessions-and-roles.test.ts:351, p:N7 · OF t:alerts.test.ts:474 · GAP: Gu, devices.
- **`POST /v1/devices/register`**: Ow t:devices.test.ts:120 · Co without `devices` t:devices.test.ts:143, p:N6b · OF t:devices.test.ts:221, p:B8 · Own dev. `403r` t:devices.test.ts:245 · Consent t:consent.test.ts:434 · GAP: Gu.
- **`POST /v1/devices/pair`**: Ow t:pairing.test.ts:65 · Co t:pairing.test.ts:95, p:N6c · OF t:pairing.test.ts:123 · Own dev. t:pairing.test.ts:145 · Consent t:consent.test.ts:417 · GAP: Gu.
- **`POST /v1/devices/pair/claim`**: live code t:pairing.test.ts:159 · unknown or expired t:pairing.test.ts:301 · reuse t:pairing.test.ts:314 · GAP: the consent 428 at claim time.
- **`GET /v1/devices`**: Ow t:devices.test.ts:258 · Own dev. p:G3 · GAP: Co, Gu.
- **`GET /v1/devices/:id`**: Ow t:devices.test.ts:276 · Sibling `403f` p:G4, p:G5 (no secret leaked) · GAP: Own dev., Co, Gu, OF.
- **`GET /v1/devices/:id/apps`**: Ow t:device-apps.test.ts:206 · Co without and with `rules` t:device-apps.test.ts:263, p:N6f · OF t:device-apps.test.ts:246, p:G26 · devices `403r` t:device-apps.test.ts:246 · GAP: Gu.
- **`POST /v1/devices/:id/apps`**: Ow and Gu `403d` t:device-apps.test.ts:164 · Own dev. t:device-apps.test.ts:32, p:G24 · Sibling t:device-apps.test.ts:137, p:G27 · OF t:device-apps.test.ts:137 · Consent t:device-apps.test.ts:184, p:J3e · GAP: Co.
- **`POST /v1/devices/:id/command`**: Ow t:devices.test.ts:22 · Co without `devices` p:N6 · OF t:devices.test.ts:69, p:B3 · Consent t:consent.test.ts:239, p:J3c · GAP: Gu, own dev. `403r`.
- **`GET /v1/devices/:id/commands`**: Own dev. t:devices.test.ts:45, p:K1 · Ow `403d` t:devices.test.ts:45, p:B11 · Consent t:consent.test.ts:211, p:J3b · GAP: Co, Gu, OF, sibling.
- **`POST /v1/devices/:id/commands/:commandId/ack`**: Own dev. t:mfa-reset.test.ts:977, p:K3 · GAP: parents, OF, sibling. The e2e has "parent cannot ack a device command (403)" (`e2e.mjs`), but e2e isn't one of the coverage sources here.
- **`GET /v1/devices/:id/commands/history`**: Ow t:devices.test.ts:816, p:B11b · GAP: Co, Gu, OF, devices.
- **`POST /v1/devices/:id/push-token`**: Own dev. t:devices.test.ts:311, p:P1 · Sibling t:devices.test.ts:333, p:P2 · Ow and Co `403d` t:devices.test.ts:356, p:P3, p:N6d · GAP: Gu, OF.
- **`POST /v1/devices/:id/telemetry`**: Ow `403d` t:devices.test.ts:607 · Own dev. t:devices.test.ts:542, p:G21 · Sibling t:devices.test.ts:607, p:G20 · OF t:devices.test.ts:590 · GAP: Co, Gu, Consent (p:J3b covers ping, rules and commands, not telemetry).
- **`POST /v1/devices/:id/activity`**: Ow `403d` t:devices.test.ts:652 · Own dev. t:devices.test.ts:703 · Sibling t:devices.test.ts:652 · OF t:social.test.ts:311 · GAP: Co, Gu, Consent.
- **`DELETE /v1/devices/:id`**: Ow t:devices.test.ts:768 · Own dev. `403r` t:devices.test.ts:768 · GAP: Co, Gu, OF.
- **`GET /v1/family/me`**: Ow t:family.test.ts:92 · Own dev. t:family.test.ts:223, p:G6 · GAP: Co, Gu.
- **`PATCH /v1/family/me`**: Ow t:timezone.test.ts:104 · GAP: Co, Gu `403o`, devices.
- **`POST /v1/family/children`**: Ow t:family.test.ts:57 · Co `403o` t:sessions-and-roles.test.ts:362 · Own dev. t:pairing.test.ts:341 · Consent t:family.test.ts:23, :40, :76, p:C1 · GAP: Gu.
- **`GET /v1/family/children/:id`**: Ow t:family.test.ts:127 · OF t:family.test.ts:149, p:B1 · GAP: Co, Gu, devices.
- **`PATCH /v1/family/children/:id`**: Ow t:family.test.ts:280 · Gu without and with `rules` t:sessions-and-roles.test.ts:332 · Consent t:consent.test.ts:399 · GAP: Co, OF, devices.
- **`DELETE /v1/family/children/:id`**: Ow t:family.test.ts:169, p:M4 · Co `403o` t:sessions-and-roles.test.ts:362, p:N6 · OF p:M3 · GAP: Gu, devices.
- **`POST /v1/family/children/:id/consent`**: Ow t:family.test.ts:332 · GAP: Co, Gu, OF, devices.
- **`GET /v1/family/children/:id/consent`**: Ow t:consent.test.ts:80 · GAP: Co, Gu, OF, devices.
- **`POST /v1/family/children/:id/consent/revoke`**: Ow t:consent.test.ts:40 · Co t:sessions-and-roles.test.ts:362 · OF t:consent.test.ts:65 · GAP: Gu, devices.
- **`GET /v1/family/export`**: Ow t:family.test.ts:392 · GAP: Co, Gu, devices.
- **`POST /v1/family/invites`**: Ow t:invites.test.ts:52, p:N4 · non-owner t:invites.test.ts:88 · GAP: Gu (as a role), devices.
- **`GET /v1/family/invites`**: Ow t:invites.test.ts:125 · GAP: Co, Gu, devices.
- **`POST /v1/family/invites/:id/accept`**: match t:invites.test.ts:139, p:N5 · mismatch t:invites.test.ts:226 · unknown t:invites.test.ts:243 · GAP: a device token (401).
- **`DELETE /v1/family/invites/:id`**: Ow, non-owner, other family t:invites.test.ts:270 · GAP: devices.
- **`POST /v1/location/ping`**: every parent role `403d` t:location-auth.test.ts:64, :81, p:G15, p:G17 · Own dev. t:location-auth.test.ts:119, p:G7b, p:G7c · Sibling t:location-auth.test.ts:135, p:G16 · device of another family t:location-auth.test.ts:103 · Consent t:consent.test.ts:179, t:location-events.test.ts:93, p:J3b · no GAP in these columns.
- **`GET /v1/location/:childId/latest`**: Ow t:geofence.test.ts:606 · OF t:geofence.test.ts:632 · Own dev. t:location-auth.test.ts:156 · Sibling t:location-auth.test.ts:170 · GAP: Co, Gu.
- **`GET /v1/location/:childId/history`**: Ow t:geofence.test.ts:646 · Own dev. and sibling t:location-auth.test.ts:186, p:G13, p:G14 · GAP: Co, Gu, OF.
- **`GET /v1/location/geofences/:childId`**: Ow t:geofence.test.ts:709 · Own dev. and sibling t:location-auth.test.ts:211 · GAP: Co, Gu, OF.
- **`POST /v1/location/geofences`**: Ow t:geofence.test.ts:721 · OF t:geofence.test.ts:816, p:B4 · Consent t:consent.test.ts:468 · GAP: Co, Gu `403p:location`, devices.
- **`DELETE /v1/location/geofences/:id`**: Ow and OF t:geofence.test.ts:838 · Own dev. `403r` t:geofence.test.ts:861 · GAP: Co, Gu.
- **`GET /v1/rules/:childId`**: Ow t:rules.test.ts:223 · Gu reads t:sessions-and-roles.test.ts:315 · OF t:rules.test.ts:187 · Own dev. t:rules.test.ts:459, p:G13 · Sibling t:rules.test.ts:473, p:G14 · Consent for the device only t:consent.test.ts:197, p:J3b · GAP: Co.
- **`PUT /v1/rules/:childId`**: Ow t:rules.test.ts:74 · OF p:B2 · Own dev. t:pairing.test.ts:355 · Consent t:consent.test.ts:289, :324, :358, p:J3 · GAP: Co, Gu.
- **`PATCH /v1/rules/:childId`**: Ow t:rules.test.ts:283 · Gu without `rules` t:sessions-and-roles.test.ts:315 · Co without `rules` p:N6 · GAP: OF, devices, Consent.
- **`POST /v1/controls/children/:childId/pause-internet`**, **`/pause`**, **`/resume-internet`**, **`/resume`**, **`/bonus`**, **`/wind-down`**, **`GET …/status`**:
  - Ow: t:controls.test.ts:89, :122, :152, :212 (pause-internet, resume-internet, bonus, wind-down, status).
  - OF on every route: t:controls.test.ts:271.
  - Consent: t:consent.test.ts:452 (pause), :224 (resume stays open), p:J3, p:J3c.
  - GAP: Co, Gu `403p:rules` on all seven, devices `403r` on all seven, and Ow on `/pause` and `/resume` (aliases).
- **`GET /v1/reports/activity`**: Ow t:social.test.ts:325 · OF t:social.test.ts:357 · GAP: Co, Gu, devices.
- **`GET /v1/reports/summary`**: Ow t:reports.test.ts:71 · OF t:reports.test.ts:120 · devices t:reports.test.ts:138 · GAP: Co, Gu.
- **`GET /v1/reports/usage`**: Ow and OF t:usage-model.test.ts:315, p:B5, p:M2 · GAP: Co, Gu, devices.
- **`GET /v1/reports/web`**: Ow and OF t:usage-model.test.ts:315, p:B5b · GAP: Co, Gu, devices.
- **`GET /v1/reports/wellbeing/:childId`**: Ow t:reports.test.ts:181 · OF t:reports.test.ts:249, p:B6 · GAP: Co, Gu, devices.
- **`GET /v1/social/events`**: Ow t:social.test.ts:222 · OF and devices t:social.test.ts:249, p:B9 (since F1) · GAP: Co, Gu.
- **`GET /v1/content/searches`**: Ow, OF and devices t:content.test.ts:151, p:B7 (since F1) · GAP: Co, Gu.
- **`GET /v1/digests/prefs`**: Ow t:reports.test.ts:271 · devices t:reports.test.ts:339 · GAP: Co, Gu.
- **`PUT /v1/digests/prefs`**: Ow t:reports.test.ts:306 · GAP: Co, Gu, devices.
- **`POST /v1/digests/send-now`**: Ow t:reports.test.ts:353 · GAP: Co, Gu, devices.
- **`POST /v1/me/push-token`**, **`DELETE /v1/me/push-token`**: Ow t:email.test.ts:326 · GAP: Co, Gu, devices.
- **`GET /v1/me/push-tokens`**: GAP in every column.
- **`GET /v1/blocklists`**: parent t:blocklists.test.ts:46 · device t:blocklists.test.ts:66 · no GAP in these columns.
- **`GET /v1/insights/apps`**: parent t:review-fixes.test.ts:101 · GAP: a device token.
- **`POST /v1/ws-ticket`**: Ow t:realtime.test.ts:76, p:L1 · Own dev. `403r` p:G6b · GAP: Co, Gu.
- **`GET /v1/ws`**: ticket flow t:realtime.test.ts:76, p:L1, p:L4, p:L5, p:L9 · `?token=` refused t:realtime.test.ts:117, :124, p:L6, p:L7, p:L7b.

**Count:** across the seven per-route columns, the largest GAP class is co-parent and guardian. Most routes
assert only the owner and the other family, so a dropped `requirePermission` or `requireOwner` on most
routes is caught by p:N6–N7 and the few role tests above, or not at all. The 2.7 probe section will add
one table-driven check per role: a co-parent and a guardian **with no permissions** against every route
whose cell is `403p`/`403o`, and **with** the permission against the same routes for the `2xx` half.

## 2. HMAC-signed device and service routes

These routes take no JWT, except `/v1/location/ping`, which accepts either. It is the only route listed twice: once in §1 for its JWT callers and once here for its signers. The caller is whoever signs
`X-FamilyShield-Signature`, and `lib/internalAuth.ts:151-216` decides which secret is accepted for which body.
Every one returns `401 invalid_signature` with a `reason` on failure.

| Route | Line | Own device secret, v2 | Sibling device secret | Other-family device secret | Global secret + known `X-FamilyShield-Caller` | Global secret, no caller | Replayed nonce | Timestamp off by more than 300 s | v1 signature (no timestamp) | Unpaired device | No signature | Consent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `POST /v1/alerts/internal` | alerts 88 | 201, or 200 on a dedupe | 400 `cross_child_alert_forbidden` (`:109`) | 400 `cross_child_alert_forbidden` | 201 | 401 `global_secret_requires_service_caller` | 401 `replay` | 401 `stale_timestamp` | 401 `legacy_signature_disabled`, unless `INTERNAL_SIGNING_ALLOW_V1=1` | 401 `device_has_no_secret` (the row is deleted on unpair) | 401 `missing_signature` | 428 (`:120`) |
| `POST /v1/content/search-event` | content 94 | 201, or 200 if not flagged | 400 `cross_child_content_forbidden` | 400 | 201 | 401 | 401 `replay` | 401 `stale_timestamp` | 401 | 401 | 401 | 428 |
| `POST /v1/content/youtube-watch` | content 186 | 201, or 200 if not flagged | 400 | 400 | 201 | 401 | 401 `replay` | 401 `stale_timestamp` | 401 | 401 | 401 | 428 |
| `POST /v1/social/scan` | social 92 | 2xx | 400 `cross_child_forbidden` (`:111`) | 400 | 2xx | 401 | 401 `replay` | 401 `stale_timestamp` | 401 | 401 | 401 | 428 |
| `POST /v1/location/ping` | location 187 | 201 | 403 `cross_child_forbidden` / `device_mismatch` (`:249-254`) | 403 | 201 | 401 | 401 `replay` | 401 `stale_timestamp` | 401 | 401 | 401 `unauthorized` | 428 |

In the sibling column the sibling signs a body that names **this** child (or this device). A body naming
only a child is accepted from any of that child's devices (`internalAuth.ts:200-213`). A body naming a
device must be signed by that device's own secret (`:188-198`).

## 3. Auth and MFA routes (`routes/auth.ts`)

These are the routes that mint or consume credentials, so the columns above don't fit them. Each row says
which credential the route accepts and what it must refuse.

| Route | Line | Accepts | Must refuse |
|---|---|---|---|
| `POST /v1/auth/register` | 193 | anyone (rate-limited, 20/min) | a taken email (no account detail leaked) |
| `POST /v1/auth/login` | 218 | email and password, plus a TOTP code when MFA is on | wrong password and unknown email with the same `401 invalid_credentials`; MFA on with no code: `401 mfa_required`; MFA on with no bound secret: `401 mfa_reenroll_required`, with no token minted (`:234-239`) |
| `POST /v1/auth/mfa/enroll` | 405 | a live parent session, or an `mfa_recovery` token whose `jti` is live in Redis (`:372-396`) | other purposes; a replacement without the password or a current code (#139) |
| `POST /v1/auth/mfa/verify` | 444 | same as enroll | same |
| `POST /v1/auth/mfa/recovery-codes` | 489 | a live parent session (`requireJwt`, `:293-310`) | every purpose token |
| `POST /v1/auth/mfa/recover` | 524 | password plus an unused recovery code | a used code; a wrong password |
| `POST /v1/auth/mfa/reset/request` | 665 | email and password | the same `401` as `/login` for an unknown email or wrong password; `409 mfa_not_enabled`, `409 no_witness`, `409 reset_already_pending`, `429 reset_limit_reached` |
| `POST /v1/auth/mfa/reset/confirm` | 765 | an `mfa_reset_confirm` token with a live `jti` | any other purpose; a reused or expired link |
| `POST /v1/auth/mfa/reset/witness` | 850 | `requestId` plus the 8-digit code from the child's device | a wrong code (5 attempts, then `401 too_many_attempts`); a request not in `mailbox_confirmed` |
| `POST /v1/auth/mfa/reset/approve` | 894 | a live session of an owner or co-parent in the requester's family, not the requester | another family: 403; the requester themselves: 403; a guardian: `403 role_not_allowed` |
| `POST /v1/auth/mfa/reset/cancel` | 920 | an `mfa_reset_cancel` token, or a witness session as for approve | other purposes; another family |
| `POST /v1/auth/mfa/reset/complete` | 992 | the requester's password after the 72-hour window | inside the window: `409 window_open`; a cancelled request: `409 request_cancelled` |
| `POST /v1/auth/mfa/reset/status` | 1123 | the requester's own credentials | another parent's `requestId`: `404 request_not_found`, byte-identical to an unknown id |
| `GET /v1/auth/mfa/reset/pending` | 1159 | a live owner or co-parent session | a guardian: `403 role_not_allowed`; no token: 401 |
| `POST /v1/auth/reset/request` | 1237 | an email | must answer the same for a known and an unknown email |
| `POST /v1/auth/reset/confirm` | 1286 | a `password_reset` token, once | reuse; any other purpose |
| `POST /v1/auth/token/refresh` | 1370 | a refresh token whose rotation record is current | a rotated (reused) refresh token: theft response, every session revoked |
| `POST /v1/auth/logout` | 1426 | anything (best-effort revocation) | — |
| `POST /v1/auth/logout-all` | 1449 | a live parent session | every purpose token |

The MFA reset rows follow ADR-0031 (`docs/adr/0031-mfa-reset-family-witness.md`). The probe already walks
most of them as `O14`-`O28`, and the coverage pass will cite each one.

## 4. Questions raised, and the decisions on them

Claude ruled on all four on #329 (2026-10-23, comment `6366294192`, checked at `87709fb`).

| Question | Decision | Fix |
|---|---|---|
| Q1: parent-side writes to telemetry, activity, apps | **Not intended → finding F2.** Data the child's phone reports must come from the phone. The parent `202` was pinned to show family scoping held after #124, not because a parent needs to write | `requireDeviceRole` on all three routes. A parent gets `403 device_role_required`. The pins change with a reason, and `e2e.mjs:342-345` moves to the agent's token |
| Q2: guardian edits a child's profile | **Not intended → finding F3.** `birthYear` sets the age that risk scoring uses (`social.ts:123`, `content.ts:132`), so it's a rules decision | `requirePermission("rules")` on `PATCH /v1/family/children/:id` |
| Q3: parent location pings | **Not intended → finding F4.** A forged ping can trigger a routine that applies rules, and it falsifies the location history. No app sends one | `/v1/location/ping` takes a device JWT or HMAC only. A parent gets `403 device_role_required`. Probe G15 and G16 are superseded, G17 names its new error, and a device-token `device_mismatch` case stays asserted |
| Q4: `ws-ticket` and purpose tokens | **Fix for consistency** (not exposure) | `isBearerSession` before the role check, so a purpose token gets `401 unauthorized` |

All four fixes landed in **#331** (verified by Claude at `a21d0ef`, merged 2026-10-23). The cells above
show the statuses after that merge, marked with the finding that changed them: `403d (F2)`,
`403p:rules (F3)`, `403d (F4)` and `401 (Q4)`. Before #331 they were `202`, `200`, `201` (`403f` for
another family) and `403r`.

The questions as originally raised (line numbers as at `bbda837`, before #331 moved them):

- **Q1.** Any parent of the family (owner, co-parent or guardian, **with no permission**) can POST a device's
  telemetry, activity and app inventory (`devices.ts:392`, `:525`, `:571`). That's because
  `requireOwnDevice` lets every parent token through (`requireFamily.ts:248`). Is a parent-side write
  intended on these three agent routes? If not, the fix is the `requireDeviceRole` gate that `/push-token`
  already uses (`devices.ts:507`). The current behaviour is pinned on purpose for two of the three:
  `test/devices.test.ts:631-633` (telemetry) and `:677-679` (activity) assert a parent's `202` ("parents stay
  family-scoped"). So answering "no" means changing a pinned test, and the reason has to be recorded.
- **Q2.** `PATCH /v1/family/children/:id` (`family.ts:174`) names no permission and no owner check, so a
  guardian with no permissions can rename a child or change their birth year. Every other child-shaping
  write names `rules`, `location` or owner.
- **Q3.** A parent may `POST /v1/location/ping` on a device's behalf (`location.ts:237-243`) with no
  `location` permission. A ping drives geofence evaluation, and a geofence can carry a `routineId` that
  auto-applies routine rules (`location.ts:44`, `:170`). Should this route need `location`, or `rules` when the
  fence carries a routine?
- **Q4.** `POST /v1/ws-ticket` answers a purpose-scoped token with `403 parent_role_required`, not the
  `401` every other route gives (`gateway.ts:22-37`; no `isBearerSession` check). It's still refused, so
  this is consistency, not exposure.

## 5. Findings (not exploitable)

### F1. Probe checks B7 and B9 call routes that don't exist, so they can't fail

Both checks accept `403` or `404`, and both call a path the API never registered, so the router answers
`404` before any guard runs:

- `services/api/scripts/qa-probe.mjs:304-305` (as at `bbda837`; this PR replaces the check): B7 calls `GET /v1/insights/${kidA}`. The only insights route is
  `GET /v1/insights/apps` (`routes/insights.ts:33`).
- `qa-probe.mjs:313-314`: B9 calls `PUT /v1/digests`. The digest routes are `/v1/digests/prefs` and
  `/v1/digests/send-now` (`routes/digests.ts:48`, `:54`, `:71`).

What I ran (local stack, `main@bbda837`) and what it printed. The last call has **no token at all**:

```
GET /v1/insights/<id>:
{"message":"Route GET:/v1/insights/some-child-id not found","error":"Not Found","statusCode":404} [404]
PUT /v1/digests:
{"message":"Route PUT:/v1/digests not found","error":"Not Found","statusCode":404} [404]
same, no token at all:
{"message":"Route GET:/v1/insights/some-child-id not found","error":"Not Found","statusCode":404} [404]
```

So B7 and B9 pass whatever the guards do. It's the `AGENTS.md` §3 class of a check that cannot fail. A
sweep of all 262 `call(...)` sites in the probe against the 89 registered routes found no others, apart from
H1, whose 404 is deliberate:

```
calls: 262 routes: 89
line 304 GET /v1/insights/${kidA}
line 313 PUT /v1/digests
line 1449 GET /v1/does-not-exist-${stamp}
```

- **Cause:** the routes these checks named were renamed or never shipped. Insights has no child-scoped route
  at all.
- **Fix (approved by Claude on #329, 2026-10-23, and made in this PR):**
  - Redefine B7 as the cross-family check for a child-scoped read the B group doesn't cover yet:
    `GET /v1/content/searches?childId=<kidA>` with `tokenB` must be `403 forbidden`.
  - Redefine B9 the same way for `GET /v1/social/events?childId=<kidA>`.
  - Both assert the exact status and the `error` body, not `[403, 404]`.
  - Record the two redefinitions in `scripts/probe-gate-acks.json` as supersessions, not removals.
- **The mutant, measured.** With the `requireFamily` preHandler removed from `content.ts:266` and
  `social.ts:166`, the probe exits 1:

  ```
  FAIL  B7 flagged searches of another family's child are refused (403 forbidden) — got 200 {"items":[]}
  FAIL  B9 social events of another family's child are refused (403 forbidden) — got 200 {"items":[]}
  ```

  With the guards restored, both pass and the probe is back to 169/0:

  ```
  PASS  B7 flagged searches of another family's child are refused (403 forbidden) — got 403 {"error":"forbidden"}
  PASS  B9 social events of another family's child are refused (403 forbidden) — got 403 {"error":"forbidden"}
  ───────────  169 passed · 0 failed · 0 targets · 0 notes · rate limit: 0 x 429  ───────────
  ```

## 6. What comes next

1. **Coverage.** Replace each code above with `probe:<check>` or `test:<file>:<line>` where it's already
   pinned, or **GAP** where it isn't.
2. **Observed statuses.** Drive every GAP cell against a local stack and record the observed status next to
   the expected one.
3. **Probe checks.** Add the GAP checks to `services/api/scripts/qa-probe.mjs` as a new lettered section
   after `O`, named for 2.7. Each check states the mutant it catches (`AGENTS.md` §3).

Exploitable findings go to Security → Report a vulnerability first, and stay out of this file until their fix
has merged.
