I have completed a thorough read of the parent-app Flutter sources and the matching Fastify API routes/Prisma schema. Here is the audit report.

## Flutter parent-app audit

### FLT-01 — Concurrent-401 token refresh race → full session revocation / logout
- **Severity**: critical
- **File**: `apps/parent-app/lib/api/client.dart:16-45` (and `services/api/src/routes/auth.ts:216-245`)
- **What breaks**: The Dio `onError` interceptor has no in-flight refresh lock or shared promise. When two requests return 401 at the same time, both read the same `refresh` token from secure storage and both `POST /v1/auth/token/refresh`. The first call rotates the token; the second presents the now-consumed token, the server's reuse detection fires (`auth.ts:223-228`) and calls `revokeAllRefreshTokens`, then the second interceptor's `catch` deletes `jwt`/`refresh` locally (`client.dart:39-42`).
- **Repro**: On a slow network, load the dashboard (family + alerts + rules + location fire in parallel) with an expired JWT. Several 401s arrive together → one refresh succeeds, the others reuse the old token → server revokes every session and the app clears storage.
- **Expected vs actual**: Expected one refresh and retries; actual a signed-out user plus revocation of all other sessions/devices (the parent is logged out everywhere).
- **Suggested fix**: Add a module-level `Future<String?>? _refreshing` single-flight guard; queue 401 callers behind the one refresh and replay their requests with the new token; treat `refresh_token_reused` as a hard logout that also updates `AuthState`.

### FLT-02 — `screenTimeTodayMinutes` is read by the UI but never sent by the API → dashboard progress always 0
- **Severity**: high
- **File**: `apps/parent-app/lib/api/models.dart:81,100`; `apps/parent-app/lib/features/dashboard/dashboard_screen.dart:114,182`; server `services/api/src/routes/family.ts:50-57`; `services/api/prisma/schema.prisma:35-49`
- **What breaks**: `Child.fromJson` reads `screenTimeTodayMinutes`, and `ChildCard` renders the headline "X / Y min" and the progress bar from it. But `GET /v1/family/me` spreads the raw Prisma `Child` row, which has no `screenTimeTodayMinutes` column (only `birthYear`, etc.), and no server code computes it. The field is present only in the fake test client (`test/fake_api_client.dart:98-99`), which is why tests are green.
- **Repro**: Log in with a child that has real screen time recorded. Every card shows `0 / 180 min` and an empty progress bar regardless of actual usage.
- **Expected vs actual**: Expected today's used minutes against the limit; actual permanent zero.
- **Suggested fix**: Compute today's `app_usage` minutes per child in `/v1/family/me` (e.g. `summarizeChildActivity`) and emit `screenTimeTodayMinutes`, or stop reading it and compute in the app from a report.

### FLT-03 — "Always allowed" apps are silently never saved (server schema drops the field)
- **Severity**: high
- **File**: `apps/parent-app/lib/api/models.dart:360-368`; `apps/parent-app/lib/features/rules/rules_editor_screen.dart:68`; server `services/api/src/routes/rules.ts:54-64,105-124`; `services/api/prisma/schema.prisma:82`
- **What breaks**: `RuleSet.toJson()` sends `alwaysAllowedApps` on every PUT, and the rules editor (Apps tab) edits it. But `RuleSetInputSchema` doesn't declare `alwaysAllowedApps` and `toRow()` doesn't map it, so Zod strips the key and Prisma never updates the column. The UI shows "Rules saved", yet the added package IDs vanish on the next load.
- **Repro**: Open a child → Edit rules → Apps → add `com.example.app` to "Always allowed" → Save → snackbar says saved → navigate away and back; the list is empty.
- **Expected vs actual**: Expected the allowlist to persist; actual silent data loss.
- **Suggested fix**: Add `alwaysAllowedApps: z.array(z.string()).default([])` to `RuleSetInputSchema`/`RuleSetPatchSchema` and map it in `toRow`.

### FLT-04 — Router has no `refreshListenable`, so a restored session is stranded on the login screen
- **Severity**: high
- **File**: `apps/parent-app/lib/app.dart:16-23`; `apps/parent-app/lib/providers/auth_provider.dart:177-184`
- **What breaks**: `GoRouter`'s `redirect` reads `authProvider` once per navigation. `bootstrap()` runs fire-and-forget when the provider is first read, but there is no `refreshListenable` wired to the auth state. On a cold start with a valid stored JWT, the redirect runs while `isAuthenticated` is still false (storage read is async), keeps the user on `/login`, and never re-evaluates when bootstrap completes.
- **Repro**: Sign in, force-stop the app, relaunch. The app shows the login screen despite a valid session; the only way forward is signing in again (or any navigation that re-runs the redirect).
- **Expected vs actual**: Expected auto-navigation to `/` after session restore; actual user is stuck on login.
- **Suggested fix**: Add a `ValueNotifier`/`Listenable` that follows `authProvider` (e.g. `ref.listen` in a provider) and pass it as `GoRouter(refreshListenable: ...)`, or read auth through a `ListenableBuilder`-driven redirect.

### FLT-05 — Pending-invites list reads the wrong envelope key (`items` vs `invites`)
- **Severity**: high
- **File**: `apps/parent-app/lib/providers/family_provider.dart:94-99`; server `services/api/src/routes/invites.ts:59-66`
- **What breaks**: `familyInvitesProvider` does `res.data['items']`, but `GET /v1/family/invites` returns `{ invites: [...] }`. `['items']` is null, so the list is always empty — both on first load and after creating an invite (`ref.invalidate(familyInvitesProvider)`).
- **Repro**: Invite a member from Family members → "Invite sent" → the "Pending invites" section stays empty, and the revoke affordance is never reachable.
- **Expected vs actual**: Expected the pending invite to appear; actual feature silently broken.
- **Suggested fix**: Read `res.data['invites']` (or accept both `invites` and `items` like the other providers).

### FLT-06 — Location history parses `p['ts']` but the API returns `p['timestamp']` → "today's route" is broken
- **Severity**: high
- **File**: `apps/parent-app/lib/providers/world_class_provider.dart:68-75`; server `services/api/src/routes/location.ts:143-158`; `services/api/prisma/schema.prisma:150`
- **What breaks**: `locationHistoryProvider` builds `LocationPing` manually with `timestamp: DateTime.tryParse(p['ts'] ...)`, but `LocationPing` rows have a `timestamp` column. Every ping ends up with a null timestamp, so the time scrubber shows "accuracy unknown" instead of a time, and the ◀/▶ steppers no-op (they `return` when `timestamp` is null — `child_detail_screen.dart:481-483`).
- **Repro**: Open a child's Location tab with any history. The route card shows only the newest point, never a time, and the steppers do nothing.
- **Expected vs actual**: Expected scrubable, time-stamped history; actual timestamps are dropped.
- **Suggested fix**: Use `LocationPing.fromJson` (which reads `timestamp`) or change `p['ts']` to `p['timestamp']`.

### FLT-07 — Refresh failure clears tokens but leaves `AuthState` authenticated (dead session)
- **Severity**: medium
- **File**: `apps/parent-app/lib/api/client.dart:37-43`; `apps/parent-app/lib/providers/auth_provider.dart:127-137`
- **What breaks**: When a refresh fails mid-session (expired/revoked refresh token), the interceptor deletes `jwt`/`refresh` from secure storage but does not notify `AuthNotifier`. `AuthState.isAuthenticated` stays true, so the router keeps showing authenticated screens while every subsequent request 401s — families render as "Failed to load", alerts as empty, etc., with no path back to login except a manual logout or app restart.
- **Repro**: Let the refresh token expire/be revoked while using the app; make an API call. Storage is wiped but the dashboard remains, showing errors with no logout redirect.
- **Expected vs actual**: Expected the app to transition to the login screen; actual a half-logged-out UI.
- **Suggested fix**: Route the interceptor's refresh-failure logout through a callback into `AuthNotifier` (or expose a shared "session ended" state) so the UI drops back to `/login`.

### FLT-08 — Location and wellbeing providers are never refreshed after first fetch (stale state)
- **Severity**: medium
- **File**: `apps/parent-app/lib/providers/family_provider.dart:75-82,160-170`; `apps/parent-app/lib/features/dashboard/dashboard_screen.dart:59`; `apps/parent-app/lib/providers/world_class_provider.dart:23-27`
- **What breaks**: The dashboard's pull-to-refresh only does `ref.invalidate(familyProvider)`. `locationProvider`, `geofencesProvider`, and `wellbeingProvider` are only invalidated by the WS `location` branch (`family_provider.dart:168`) — but the server never emits a `location` event (its only WS publishes are `alert` and `live_activity`, per `services/api/src/realtime/gateway.ts` and route grep). So a child's map marker and wellbeing ring stay frozen until the app restarts; a child that had "No location yet" (404 → error state) never recovers when the device later starts pinging.
- **Repro**: Open the map, then have the child device send new pings. Markers don't move. Likewise the dashboard wellbeing ring never updates during the session.
- **Expected vs actual**: Expected live/staleness-invalidated location and wellbeing; actual one-shot fetch.
- **Suggested fix**: Invalidate `locationProvider`/`wellbeingProvider` on pull-to-refresh and on a real server `location` WS event; or add a periodic refresh/poll for these providers.

### FLT-09 — `install_request` alert actions are unreachable dead code
- **Severity**: low
- **File**: `apps/parent-app/lib/features/alerts/alerts_screen.dart:111-123`; server `services/api/src/routes/alerts.ts:22-32`
- **What breaks**: The alert detail dialog renders "Allow"/"Block this app" only for `category == 'install_request'`, but the API's `InternalAlertSchema` category enum doesn't include `install_request`, and no route ever creates such an alert. The block/allow flow (and its rules-merge PUT) can never be exercised.
- **Repro**: N/A — no such alert can exist in the system.
- **Expected vs actual**: Expected the Feature #8 install-request actions to fire for install requests; actual dead UI.
- **Suggested fix**: Either emit `install_request` alerts server-side (there's an unused `InstallRequest` table, `schema.prisma:133-141`) or remove the branch.

### FLT-10 — Rules editor can hit a hard overlap rejection with no escape hatch
- **Severity**: low
- **File**: `apps/parent-app/lib/features/rules/rules_editor_screen.dart:61-79`; server `services/api/src/routes/rules.ts:127-134,148-149`
- **What breaks**: The editor PUTs without `allowOverlap`. If the parent configures bedtime and school windows that share any minute, the server returns 400 with the overlap message; the UI has no way to send `allowOverlap: true`, so those settings can never be saved. The error is surfaced in a banner (not swallowed), but there's no guidance or override.
- **Repro**: Set bedtime 20:00–07:00 and school hours that start before 07:00 (or school hours that run past bedtime start) → Save → persistent 400.
- **Expected vs actual**: Expected a way to accept overlapping windows (the server supports `allowOverlap`); actual a blocked save.
- **Suggested fix**: Add an "Allow overlapping windows" switch in the Screen time tab that includes `allowOverlap: true` in the PUT body, or pre-validate client-side with the same logic.

### Verified solid
- **Dart `switch` fall-through**: I empirically confirmed (Dart 3.13) that the WS dispatch `switch` in `family_provider.dart:160-177` does **not** fall through — non-empty cases break implicitly. Not a bug.
- **`kRecommendedCategories`** (`models.dart:198-212`) matches `DEFAULT_BLOCKED_CATEGORIES` (`packages/shared-types/src/world-class.ts:14-17`) exactly — 13 items, same order.
- **Server-URL handling** (`server_provider.dart:20-95`): normalization, scheme-less input, trailing-slash strip, and the empty-baseUrl guard are all correct.
- **Alerts `ack` query**: `AlertFilter.toQuery`/`unacknowledgedCountProvider` send `"true"`/`"false"` strings, matching the API's `z.enum(["true","false"])` (`alerts.ts:15`).
- **Social monitoring + contact allowlist round-trip**: `RuleSet.toJson()` sends `socialMonitoring` and `contactAllowlist`, and both are present in `RuleSetInputSchema`/`toRow` — those save correctly (unlike `alwaysAllowedApps`).
- **Logout and device commands**: `logout()` revokes server-side then deletes `jwt`/`refresh` from secure storage; `ring`/`lock`/`unlock`/`pause`/`resume` are all valid `CommandSchema` values (`devices.ts:22-36`).

**Notes on evidence quality**: FLT-01, FLT-02, FLT-03, FLT-04, FLT-05, FLT-06, and FLT-07 are verified by direct code reading on both app and server sides (field names, route shapes, Prisma columns). FLT-08 and FLT-09 are verified by grep across `services/api/src` confirming no `location` WS event and no `install_request` alert producer; the conclusion depends on that grep being complete, but it covered every `publishFamilyEvent` call site. FLT-10 is verified against the server's overlap validation but its real-world trigger frequency is a judgment call.