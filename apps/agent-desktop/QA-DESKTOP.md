# QA-DESKTOP — Windows agent (`apps/agent-desktop`) review

Date: 2026-09-15 · Reviewer: DESKTOP QA agent · Baseline: build green, 13/13 tests → Final: build green, 64/64 tests.

Scope: line-by-line review of every `Services/*.cs` against docs/SPEC.md §8 and §14.3,
plus a feature-correctness gap (routines) that the parent app can send but the agent ignored.

## Per-service checklist

### WebFilterProxy.cs — local filtering proxy (127.0.0.1:8877)
- Purpose: block listed hosts with a 200 text/html page, SafeSearch-rewrite google/bing/youtube,
  log URLs to SQLite, own the WinINET system proxy while running.
- Reviewed: block-page response (200 + `Content-Type: text/html`, per spec); system-proxy
  set/revert (previous `ProxyEnable`/`ProxyServer` saved before overwrite, restored on stop,
  WinINET refreshed via `InternetSetOption`); fail-open startup (worker keeps running when the
  proxy can't bind); throttled `web_threat` alerts (1/min).
- Bugs found & fixed:
  1. **SafeSearch duplicated query params** — `AppendQuery` blindly appended, so a URL already
     carrying `safe=active` (a child loosening the filter) kept working. Now `SafeSearch.SetQueryParam`
     *replaces* any existing key case-insensitively, preserves other params and the `#fragment`.
  2. **Host matching used `Contains`** — `notgoogle.com`/`mybing.com` were rewritten as if they
     were Google/Bing. Now label-boundary aware: `google.` prefix / `.google.` infix (covers
     `google.co.uk`, `www.google.de`), exact-or-subdomain for `bing.com`/`youtube.com`.
- Moved: rewrite logic extracted to pure `SafeSearch` (unit-tested).
- Residual: HTTPS CONNECT tunnels are not filtered (no trusted root CA; documented NOTE in code);
  `ProxyOverride` is not managed (localhost traffic is proxied); a hard crash leaves the system
  proxy pointing at a dead proxy until next clean run; domains literally named `google.<anything>`
  (e.g. `google.example.com`) still get the harmless `safe=strict` param.

### LocalRuleStore.cs — SQLite rules/telemetry store
- Purpose: persist synced ruleset + blocklists, `ShouldBlock`, per-day app usage, URL log,
  telemetry upload cursor.
- Reviewed: `ShouldBlock` precedence allowed → blocked → category (correct); suffix matching has
  a label boundary in both layers (`DomainMatches` and the SQL `LIKE '%.' || domain`) —
  `badexample.com` does **not** match `example.com` (tested); schema init; lazy reopen; day key
  (`yyyy-MM-dd` local) is stamped per write, so `app_usage` day rollover is safe.
- Bugs found & fixed:
  3. **App-usage minutes lost after upload** — the `ON CONFLICT` upsert kept `uploaded = 1`, so
     minutes accrued after a successful upload were never sent. The server keeps only the *latest*
     batch (Redis snapshot), so the row now re-flags `uploaded = 0` on every accrual and is
     re-uploaded with cumulative totals.
  4. **URL-log cursor race** — `MarkTelemetryUploaded()` marked *all* pending rows, including rows
     the proxy logged between `GetUnuploadedTelemetry()` and the mark (dropped unsent). The batch
     now carries `UrlLogCursor` (max row id read) and only ids ≤ cursor are marked.
- Residual: blocklist domains containing SQL `LIKE` wildcards (`%`/`_`) would act as patterns
  (server-controlled data, low risk); `MinutesUsedToday()` only sums processes tracked by
  `time_limit` rules, so the global screen-time cap sees only tracked apps (design limitation,
  see ScreenTimeEnforcer).

### ProcessMonitor.cs — process polling/enforcement (5 s)
- Purpose: match AppRules, kill blocked apps, account `time_limit` minutes, enforce routines.
- Bugs found & fixed:
  5. **Double-counted minutes** — two rules naming the same process each added 5 s per tick.
     Seconds are now accumulated once per process name per tick.
  6. **`time_limit` never enforced** (spec gap) — minutes were counted but nothing happened at the
     limit. Over-limit processes are now killed + `screen_time_exceeded` alert (throttled 5 min).
- Feature added (spec gap): **routine enforcement**. `RuleSetDto.routines` is now parsed into
  `RoutineSnapshot`; each tick computes `RuleSetSnapshot.ActiveRoutineBlockedApps(DateTime.Now)`
  and kills + alerts (`app_blocked`) for those processes, even without an explicit AppRule —
  mirroring the Android RuleEngine ordering (routines evaluated before per-app allow rules).
  Overnight windows are credited to their start day (a Mon 22:00–02:00 window is active Tue 01:00).
  Day numbers: 1=Mon..7=Sun (ISO, as sent by the parent app) with 0=Sun also accepted.
  Pure logic lives in `TimeWindows` + `RuleSetMapper` (unit-tested, incl. wrap-midnight).
- Residual: sub-minute seconds accrued across midnight flush into the new day (≤59 s
  misattribution); routine `allowedApps` allowlist semantics (Android blocks non-listed apps
  during such routines) is parsed but not enforced on desktop.

### ScreenTimeEnforcer.cs — daily cap + bedtime
- Reviewed: weekend/weekday switch (now `RuleSetSnapshot.EffectiveDailyLimit`, tested); overlay
  show/hide is idempotent (`LockOverlay.Show` no-ops while visible), so hovering at the limit does
  not thrash; `limit <= 0` = uncapped; bedtime re-locks every 60 s tick by design.
- Fixed:
  7. **Bedtime window bound semantics** — inclusive end made 21:00–07:00 still lock at exactly
     07:00:xx. Switched to half-open `[start, end)` via shared `TimeWindows.IsInWindow`, matching
     the Android RuleEngine (overnight OR-logic unchanged).
- Residual: the global cap only counts minutes recorded by `time_limit` app rules (untracked apps
  don't add screen time) — counting all foreground time would need a different sampler.

### RuleSyncService.cs — rule/command polling (60 s)
- Reviewed: `lock` (agent-owned overlay, so `unlock` can dismiss), `unlock`, `rules_updated`
  (re-sync), `sos_clear` (no-op locally, documented), unknown types logged; `ChildId`/`DeviceId`
  read from `AgentConfig` (env overrides applied there, per §14.3).
- Fixed:
  8. **`ring` stalled the poll loop ~5 s** — `Console.Beep` loop now runs on a background task.
- Residual: first rule sync happens 60 s after start (PeriodicTimer); alerts are unsigned unless
  `INTERNAL_HMAC_SECRET` is set (server then 401s and the alert is dropped silently).

### TelemetryUploader.cs — upload every 5 min
- Reviewed: always POSTs (battery doubles as heartbeat / lastSeen refresh, per spec §8);
  `GetSystemPowerStatus` mapping (255 = no battery → 100); failure keeps rows buffered.
- Fixed via LocalRuleStore #3/#4 (cursor + cumulative re-upload semantics).

### AgentConfig.cs — persisted identity (§14.3)
- Reviewed: load/save beside the exe (`AppContext.BaseDirectory`), env overrides
  (`API_BASE`/`DEVICE_JWT`/`DEVICE_ID`/`CHILD_ID`), corrupt file → null (re-pair),
  skip-unchanged save. No bugs. Covered by existing tests.

### ApiClient.cs — typed HTTP client
- Reviewed: JWT bearer from config; telemetry/rules/commands/alerts paths match the API routes;
  HMAC `X-FamilyShield-Signature` on `/v1/alerts/internal` when the secret is configured.
  No bugs. Residual: unsigned alerts are rejected server-side and dropped (fire-and-forget callers).

### PairingService.cs / PairingDialog.cs — first-run pairing (§14.1/§14.3)
- Reviewed: claim response parsing verified against `services/api` (`201 { device:{id}, token,
  childId, familyId }`; bare-string `device` also tolerated); 404/non-201 → null; network errors
  surface to the dialog; STA-thread dialog + non-interactive console fallback. No bugs.

### LockOverlay.cs — topmost PIN overlay
- Reviewed: `Show`/`Hide` marshal to the dedicated STA UI thread (`Send`), idempotent show,
  form-closed cleanup, PIN check client-side by design.
- Fixed:
  9. **`EnsureStarted` race** — concurrent first `Show` calls could start two message loops;
     startup is now serialized under a lock.

## Tests
- Before: 13 (LocalRuleStore 7, AgentConfig 6). After: **64, all green.**
- New: `SafeSearchTests` (21 cases: host shapes, param replacement, fragment, case),
  `TimeWindowsTests` (7: half-open bounds, overnight wrap, day-of-week + previous-day crediting),
  `RuleSetMapperTests` (18: process-name normalization, routine mapping/day encoding, weekend
  switch, ActiveRoutineBlockedApps, JSON round-trip), 5 new `LocalRuleStoreTests` facts
  (suffix boundary, allow-over-block precedence, cursor race, empty-batch ack, cumulative
  app-usage re-upload). Existing 13 kept green (one updated for the cursor signature).

## Cross-component note (out of desktop scope, flagged)
`services/api` `RoutineSchema` validates `days` as 0..6, but the parent app sends 1..7
(7 = Sunday) — a Sunday routine PUT is rejected by the API. The desktop mapper tolerates both
encodings, but the API/parent-app contract should be reconciled.
