## Windows agent audit

Scope verified against `apps/agent-desktop` sources (all `Services/*.cs`, `Program.cs`, `.csproj`, `reset-proxy.bat`, xunit tests, `QA-DESKTOP.md`). Line numbers are from the files as read.

### Findings (ranked)

- **ID**: WIN-01
- **Severity**: high
- **File**: `apps/agent-desktop/Services/LockOverlay.cs:100-106` (form setup); re-show logic `apps/agent-desktop/Services/ScreenTimeEnforcer.cs:72` vs `RuleSyncService.cs:214-235`
- **What breaks**: The PIN overlay is a plain topmost `Form` with `FormBorderStyle.None`, `WindowState.Maximized`, `TopMost=true`, and **no `FormClosing`/`WndProc` override**. Alt+F4 still delivers `WM_SYSCOMMAND/SC_CLOSE` and WinForms closes the form; the `FormClosed` handler just nulls `_form`. For parent-initiated `lock`/`pause`/`wind_down` the overlay is shown exactly once and never re-asserted, so the child dismisses it permanently. `WindowState.Maximized` covers only the primary monitor; secondary displays remain fully interactive. Screen-time re-shows on the 60 s tick, but that still yields repeated ~60 s windows.
- **Repro**: Parent sends `lock`. Overlay appears. Child presses Alt+F4 → overlay vanishes and stays gone (no periodic re-show for `lock`/`pause`/`wind_down`). Or drag/open an app on a second monitor and interact there.
- **Expected vs actual**: Lock/pause should persist until parent PIN or parent `unlock`; actual is one Alt+F4 (or a second monitor) defeats it.
- **Suggested fix**: Handle `FormClosing`/`WM_SYSCOMMAND` to cancel `SC_CLOSE`, cover all screens (one form per screen or `SetWindowPos` spanning the virtual desktop), and re-assert the overlay from the 60 s enforcer for `lock`/`pause` states, not only for the screen-time cap. *(Alt+F4-on-borderless-form is standard WinForms behavior — verified by code, not by running a build.)*

---

- **ID**: WIN-02
- **Severity**: high
- **File**: `apps/agent-desktop/Services/ScreenTimeEnforcer.cs:57-63`
- **What breaks**: Bedtime uses `LockWorkStation()` — the child's *own* Windows account lock. The child knows their Windows password and simply logs back in. Enforcement is only the 60 s re-lock loop; if the child kills the agent (Task Manager → End Task) the re-lock stops and the lock is gone for the rest of the night. Nothing ties the lock to the parent PIN.
- **Repro**: Set bedtime 21:00–07:00. At 21:00 the workstation locks. Child enters their normal Windows password → desktop returns. They have up to 60 s to either use the PC or Ctrl+Shift+Esc → kill `OSRA.Agent.exe`; after that no re-lock occurs.
- **Expected vs actual**: Bedtime should be hard to escape without a parent; actual is it's the user's own login lock plus a killable re-lock loop.
- **Suggested fix**: Combine the real lock with the agent-owned PIN overlay (like `lock`) on resume, and/or run the re-lock as a protected process/service so the child can't simply end it.

---

- **ID**: WIN-03
- **Severity**: high
- **File**: `apps/agent-desktop/Services/ProcessMonitor.cs:68`, `:150-175`, `:383-393`; consumed at `apps/agent-desktop/Services/ScreenTimeEnforcer.cs:68`
- **What breaks**: Two independent samplers both write `app_usage` every 5 s tick for the *same* minute: `AccumulateForegroundMinutes()` writes the foreground process (line 389), and the `time_limit` rule branch writes `rule.ProcessName` (lines 157-164). When a time-limited app is in the foreground both fire, so its minute is counted twice. `MinutesUsedToday()` sums all rows, so both the per-app `time_limit` and the global daily cap are reached at ~2× speed (per-app also double-counts when the rule name matches the real process name, e.g. `chrome`, `discord`, `steam`). The `countedThisTick` dedupe only prevents two *rules* colliding, not foreground-vs-rule.
- **Repro**: Create a `time_limit` rule for `chrome.exe` (limit 30 min). Child uses Chrome in the foreground. At ~15 real minutes the process is killed and `screen_time_exceeded` fires; the daily cap also counts Chrome twice.
- **Expected vs actual**: 30 minutes of allowed use; actual is ~15.
- **Suggested fix**: Make the foreground sampler and the per-app `time_limit` sampler share one accumulator (attribute a tick to exactly one bucket), or exclude foreground-derived rows from `MinutesUsedToday(process)` when a `time_limit` rule already tracks that process.

---

- **ID**: WIN-04
- **Severity**: high
- **File**: `apps/agent-desktop/Services/ProcessMonitor.cs:383-393` and `:379-380`; `apps/agent-desktop/Services/LocalRuleStore.cs:55`
- **What breaks**: The foreground sampler has no idle/lock detection. When there is no foreground window it records `"idle"` (label from `ForegroundAppLabel(null)`); when the workstation is locked (bedtime) or the child walks away, the sampler keeps adding 5 s/tick, flushing whole minutes to `app_usage["idle"]` (or the last foreground app). `ScreenTimeEnforcer`'s `MinutesUsedToday()` sums everything, so the daily budget is consumed overnight/locked/idle.
- **Repro**: Set a 120-min daily cap and bedtime 22:00. Child locks/leaves the PC on overnight. Next morning `MinutesUsedToday()` already includes hours of "idle", so the overlay shows "limit reached" immediately on unlock.
- **Expected vs actual**: Idle/locked time should not burn the child's screen-time budget; actual is it does. *(Whether `GetForegroundWindow` returns 0 or the last window while locked is desktop-dependent — the design has no lock check either way, so some process/`idle` accrues.)*
- **Suggested fix**: Pause accrual when `GetForegroundWindow()==0`, when the session is locked (`WTSRegisterSessionNotification`/`SessionSwitch`), or after an idle threshold (`GetLastInputInfo`); never record an `"idle"` pseudo-process into `app_usage`.

---

- **ID**: WIN-05
- **Severity**: high
- **File**: `apps/agent-desktop/Services/ProcessMonitor.cs:130` and `:311`; `apps/agent-desktop/Services/LocalRuleStore.cs:263-275`; `apps/agent-desktop/Services/Dtos.cs:441-445`
- **What breaks**: Blocking matches by process *name only* (`Process.GetProcessesByName`, `blocklist_apps.name`). Renaming `minecraft.exe` → `m1.exe` (or copying it to a new name) changes `ProcessName`, so the rule/blocklist never matches and no alert fires. The same name-matching also means a second local user/session (`runas /user:...`) that the agent can't kill (AccessDenied → caught and logged as debug) escapes silently.
- **Repro**: Block `notepad.exe`. Child copies `C:\Windows\System32\notepad.exe` to `Desktop\notes.exe` and runs it — it stays open indefinitely with no kill and no `app_blocked` alert.
- **Expected vs actual**: Blocked executable should stay blocked regardless of file name; actual is a rename/copy defeats it.
- **Suggested fix**: Match on file path and/or file hash in addition to name (read `Process.MainModule.FileName` where permitted), and escalate/alert on kill failures rather than silently logging at Debug.

---

- **ID**: WIN-06
- **Severity**: high
- **File**: `apps/agent-desktop/Services/WebFilterProxy.cs:242-252`; VPN handling `apps/agent-desktop/Services/RuleSyncService.cs:169-190`
- **What breaks**: The filter installs only the **WinINET** proxy (HKCU `Internet Settings`). Windows **WinHTTP** clients (services, Windows Update, many native tools/launchers) and apps with their own proxy settings (Firefox "No proxy", `curl --noproxy`, games) do not read it and bypass the filter entirely. VPN tunnels only raise a throttled `vpn_detected` **alert** — nothing blocks or closes the tunnel, so a child running a VPN app routes all traffic around the proxy. No code touches WinHTTP (`netsh winhttp`) or blocks TAP/TUN/WireGuard adapters.
- **Repro**: Child installs a VPN app or launches a WinHTTP-based downloader; browse a blocked domain — page loads, no block page, and (for WinHTTP/per-app) no alert is raised either.
- **Expected vs actual**: A parental web filter should not be trivially bypassed by the transport stack; actual is WinHTTP/per-app/VPN traffic is unfiltered (VPN is only *reported*).
- **Suggested fix**: Also set the WinHTTP proxy (or document this as a known gap), block/prompt on VPN adapters instead of alert-only, and detect per-app proxy overrides where feasible.

---

- **ID**: WIN-07
- **Severity**: medium
- **File**: `apps/agent-desktop/Services/WebFilterProxy.cs:242-252`; `apps/agent-desktop/Services/TamperChecks.cs:40-62`
- **What breaks**: `SetSystemProxy` never writes/clears `ProxyOverride`, and the tamper check reads only `ProxyEnable`/`ProxyServer`. A child can add arbitrary `ProxyOverride` entries (e.g. `youtube.com;*.google.com`) in Windows proxy settings and those hosts bypass the filter, with **no tamper alert** (ProxyServer still equals `127.0.0.1:8877`). On machines with the Windows default `<local>` override, single-label hosts also bypass silently.
- **Repro**: In Windows proxy settings add `youtube.com` to the bypass list. Browse youtube.com → loads unfiltered; no `tamper`/`web_threat` alert appears in the parent app.
- **Expected vs actual**: Bypass-list tampering should be detected/cleared; actual is it's invisible to the tamper check.
- **Suggested fix**: Set `ProxyOverride` to an explicit safe value on start (and restore on stop), and include it in `ReadProxySettings`/`ShouldAlertProxyDisabled`. *(The default `<local>` behavior depends on the machine's existing override — flagged as environment-dependent.)*

---

- **ID**: WIN-08
- **Severity**: medium
- **File**: `apps/agent-desktop/Services/WebFilterProxy.cs:143-196` (esp. 157-166, 177, 190-193); `apps/agent-desktop/Services/LocalRuleStore.cs:281-292`
- **What breaks**: `OnBeforeRequest` wraps everything in one `try/catch` that only logs. If `_store.LogUrl`/`LookupCategory`/`ShouldBlock` throws (corrupt/locked SQLite, disk full), the handler returns without calling `e.Ok(...)`, and Titanium forwards the request — so a blocked site, or even **paused** traffic (`LogUrl` is called *before* the pause block page), goes through unfiltered. Separately, before the first successful rule sync (and whenever `_store.Current` is null, e.g. server unreachable at startup), `ShouldBlock` returns `false` and everything is allowed.
- **Repro**: With the internet paused, make `agent.db` unreadable (e.g. lock it or fill the disk); browse a site → it loads despite pause. Or cold-start the agent with the API server unreachable → web filtering is a pass-through until the first sync.
- **Expected vs actual**: Block/pause should fail closed; actual is fail-open on any handler exception or missing rules.
- **Suggested fix**: Sinkhole/deny on error (call `e.Ok(blockPage)` in a `catch` when a block/pause decision could not be completed), and treat "no synced rules" as deny-by-default (or at least surface it to the parent).

---

- **ID**: WIN-09
- **Severity**: medium
- **File**: `apps/agent-desktop/Services/ProcessMonitor.cs:95-121`; contract at `apps/agent-desktop/Services/Dtos.cs:94`
- **What breaks**: The routine allowlist kills "everything not in `allowedApps`" and does **not** consult `AlwaysAllowedApps` (documented as "beating every block/limit"). So an app the parent marked always-allowed (school portal, browser) is terminated during a routine whose `allowedApps` doesn't list it. It also kills `explorer.exe` and other shell/background user processes; Windows restarts them and the next 5 s tick kills them again → taskbar/desktop flicker loop during the whole window.
- **Repro**: Add `chrome` to alwaysAllowedApps and create a routine 09:00–10:00 with `allowedApps=["word"]`. At 09:00 Chrome is killed anyway, and explorer is killed/restarted every tick.
- **Expected vs actual**: Always-allowed apps survive every routine; actual is the routine allowlist overrides them and also thrashes the shell.
- **Suggested fix**: Union `rules.AlwaysAllowedApps` into the routine allowlist (and decide whether `explorer`/shell processes should be exempted from whole-session allowlists).

---

- **ID**: WIN-10
- **Severity**: medium
- **File**: `apps/agent-desktop/Services/LocalRuleStore.cs:55`; `apps/agent-desktop/Services/ScreenTimeEnforcer.cs:55-58`; `apps/agent-desktop/Services/TimeWindows.cs:13-35`
- **What breaks**: All enforcement derives from the local clock (`DateTime.Now`/`TimeOnly.FromDateTime`). The child can change the system clock to exit the bedtime/routine window, or roll the date back so `Today` (`yyyy-MM-dd` local) becomes a past day with no `app_usage` rows — instantly resetting `MinutesUsedToday()` to 0 and dismissing the screen-time overlay. Clock skew is never validated (no server time reference).
- **Repro**: At bedtime, child sets the clock to 15:00 → `IsInWindow` false, lock not re-applied; or during the screen-time overlay, child sets the date back one day → `used` drops to 0, overlay hides.
- **Expected vs actual**: A child can't reset enforcement by editing the clock; actual is the whole rule engine trusts an unauthenticated local clock.
- **Suggested fix**: Record/compare wall-clock monotonicity (e.g. persist last-seen timestamp and treat large backward jumps as tampering) and/or use a server-provided time when available.

---

- **ID**: WIN-11
- **Severity**: medium
- **File**: `apps/agent-desktop/Services/AgentConfig.cs:21-30` and `:69-77` (esp. 75)
- **What breaks**: `agent.config.json` is written in plaintext (`File.WriteAllText`, default ACL) next to the exe, containing `DeviceJwt` and `HmacSecret`. The child user runs the agent and can read the file, extracting the device JWT and the HMAC secret that signs `/v1/alerts/internal`. With those the child can forge signed alerts or impersonate the device. No ACL hardening is applied (unlike a DPAPI/`ProtectedData` or per-user encrypted store).
- **Repro**: Child opens `%LOCALAPPDATA%`-installed or exe-adjacent `agent.config.json` → reads `deviceJwt` and `hmacSecret`; uses the HMAC to sign a spoofed `X-FamilyShield-Signature` alert or replay the bearer token.
- **Expected vs actual**: Credentials should be unreadable to the monitored user; actual is plaintext in a user-readable file.
- **Suggested fix**: Encrypt secrets at rest (`ProtectedData`/DPAPI scoped to the agent), restrict the file ACL, and consider storing the config under a location the child user can't trivially read.

---

- **ID**: WIN-12
- **Severity**: low
- **File**: `apps/agent-desktop/Services/LocalRuleStore.cs:349-366` (and `:369-389`, `:40-52`)
- **What breaks**: `url_log` gets one row per proxied request and rows are only ever marked `uploaded=1`, never deleted; `app_usage` and `agent_state` (`bonusMinutes:{day}`) accumulate one row per process/day forever. There is no retention/VACUUM/cleanup anywhere. Over weeks of browsing `agent.db` grows without bound and the SQLite queries (`SELECT ... WHERE uploaded=0 ORDER BY id`) slow down.
- **Repro**: Run the agent for a month with normal browsing; inspect `%LOCALAPPDATA%\FamilyShield\agent.db` — `url_log` holds the full browsing history, size grows indefinitely, and there's no prune path.
- **Expected vs actual**: Logs should be bounded and old rows purged after upload/retention; actual is unbounded growth and no retention (also a privacy issue — full URL history stays on disk indefinitely).
- **Suggested fix**: Delete uploaded `url_log` rows (or age them out after N days), purge stale `app_usage`/`bonusMinutes` day rows, and run periodic `PRAGMA optimize`/VACUUM.

### Verified solid

- Proxy lifecycle is clean: `WebFilterProxy` saves/restores `ProxyEnable`/`ProxyServer`, refreshes WinINET, and stops/disposes the `ProxyServer` in a `finally`; `reset-proxy.bat` clears the HKCU proxy for the documented force-kill case (`WebFilterProxy.cs:85-107`, `reset-proxy.bat:5-6`).
- `ShouldBlock` precedence (allowed → blocked → category) and label-boundary suffix matching are correct and unit-tested (`LocalRuleStore.cs:281-292`, `DomainMatches`).
- The URL-log upload cursor (`id <= maxUrlLogId`) correctly avoids marking rows logged mid-upload as sent, and `app_usage` re-flags `uploaded=0` on accrual for cumulative re-upload (`LocalRuleStore.cs:438-453`).
- Tamper detection correctly distinguishes "proxy never started" from "child disabled it" via `AgentStatus.ProxyRunning`, with a 1-hour throttle (`TamperChecks.cs:59-62`, `RuleSyncService.cs:146-162`).
- Alert signing uses the paired `HmacSecret` (with `INTERNAL_HMAC_SECRET` env fallback), not just env (`ApiClient.cs:97-103`).
- Time-window math is solid: half-open `[start,end)` with midnight wrap, overnight routine day-crediting, and corrupt config/stored-ruleset are handled gracefully and covered by tests (`TimeWindows.cs:13-35`, `AgentConfig.cs:47-50`, `LocalRuleStore.cs:134-143`).