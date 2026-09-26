using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace FamilyShield.Agent.Services;

/// <summary>Polls running processes every 5 s and enforces blocked-app rules, per-app time limits and the pause allowlist (#9).</summary>
public sealed class ProcessMonitor : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan AlertThrottle = TimeSpan.FromMinutes(5);

    private readonly ILogger<ProcessMonitor> _log;
    private readonly LocalRuleStore _store;
    private readonly ApiClient _api;
    private readonly AgentConfig _config;
    private readonly Dictionary<string, DateTime> _lastAlert = new();
    private readonly Dictionary<string, DateTime> _pauseKillThrottle = new();
    private readonly Dictionary<string, double> _accumulatedSeconds = new();
    private double _foregroundSeconds;

    /// <summary>Process name of the current foreground window, resolved every tick; null when unknown (#29).</summary>
    public string? LastForegroundProcess { get; private set; }

    /// <summary>Creates the monitor.</summary>
    public ProcessMonitor(ILogger<ProcessMonitor> log, LocalRuleStore store, ApiClient api, AgentConfig config)
    {
        _log = log;
        _store = store;
        _api = api;
        _config = config;
    }

    /// <summary>Polls until the worker stops; individual tick failures are logged, never thrown.</summary>
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(PollInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try
                {
                    Tick();
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "ProcessMonitor tick failed");
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    private void Tick()
    {
        var rules = _store.Current;
        if (rules is null) return;

        // Tracked for reporting (e.g. alert metadata and trace logs).
        var foregroundTitle = GetForegroundWindowTitle();
        // Feature #29: resolve the foreground PROCESS (not just the window title) so the live
        // feed and app_usage activity events name the app; 'idle' when no window has focus.
        LastForegroundProcess = GetForegroundProcessName();
        AccumulateForegroundMinutes();
        var countedThisTick = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Feature #9/#11: while the internet is paused, terminate every user process whose name
        // is NOT in alwaysAllowedApps (always-allowed beats pause, mirroring the Android
        // RuleEngine ordering). Evaluated first so nothing else re-kills an allowed survivor.
        if (_store.Paused)
        {
            EnforcePauseAllowlist(rules);
        }

        // 1. Scheduled routines (§2 Routine): processes listed in blockedApps of an active
        // window are killed like blocked apps, even when no explicit AppRule exists.
        foreach (var processName in rules.ActiveRoutineBlockedApps(DateTime.Now))
        {
            if (KillByName(processName) > 0)
            {
                _ = SendAlertAsync(processName, "app_blocked",
                    $"Blocked app started: {processName}",
                    $"OSRA terminated '{processName}' during a scheduled routine window.",
                    foregroundTitle);
            }
        }

        // 1b. Routine allowlists (BUG-004): when an active routine declares allowedApps, only
        // those processes may run — everything else is terminated (mirrors Android semantics).
        // Session-0 (services/system) processes and the agent itself are never touched.
        var routineAllowed = rules.ActiveRoutineAllowedApps(DateTime.Now);
        if (routineAllowed.Count > 0)
        {
            var selfId = Environment.ProcessId;
            Process[] all;
            try { all = Process.GetProcesses(); }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Could not enumerate processes for the routine allowlist");
                all = [];
            }
            foreach (var process in all)
            {
                try
                {
                    if (process.Id == selfId || process.ProcessName.Length == 0) continue;
                    if (routineAllowed.Contains(process.ProcessName)) continue;
                    if (process.SessionId == 0) continue; // system/services session
                    process.Kill(entireProcessTree: true);
                    _log.LogInformation("Routine allowlist: terminated {Process}", process.ProcessName);
                }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "Could not terminate a process under the routine allowlist");
                }
            }
        }

        // 2. Per-app rules.
        foreach (var rule in rules.AppRules)
        {
            if (rule.ProcessName.Length == 0) continue;
            Process[] processes;
            try
            {
                processes = Process.GetProcessesByName(rule.ProcessName);
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Could not enumerate processes for {Name}", rule.ProcessName);
                continue;
            }

            try
            {
                if (rule.Action == "block" && processes.Length > 0)
                {
                    // NOTE: simplest enforcement per spec — always kill + alert; an overlay per
                    // blocked app is not implemented on desktop.
                    KillAll(processes, rule.ProcessName);
                    _ = SendAlertAsync(rule.ProcessName, "app_blocked",
                        $"Blocked app started: {rule.AppName}",
                        $"OSRA terminated the blocked process '{rule.ProcessName}'.",
                        foregroundTitle);
                }
                else if (rule.Action == "time_limit" && processes.Length > 0)
                {
                    // NOTE: a minute is counted when the process is running at sample time; the
                    // 5 s samples are accumulated and whole minutes are flushed to the store.
                    // Duplicate rules for the same process must not count the same 5 s twice.
                    if (countedThisTick.Add(rule.ProcessName))
                    {
                        var seconds = _accumulatedSeconds.GetValueOrDefault(rule.ProcessName) + PollInterval.TotalSeconds;
                        if (seconds >= 60)
                        {
                            var minutes = (int)(seconds / 60);
                            _store.AddAppMinutes(rule.ProcessName, minutes);
                            seconds -= minutes * 60;
                        }
                        _accumulatedSeconds[rule.ProcessName] = seconds;
                    }

                    if (TimeLimitReached(rule))
                    {
                        KillAll(processes, rule.ProcessName);
                        _ = SendAlertAsync(rule.ProcessName, "screen_time_exceeded",
                            $"Time limit reached: {rule.AppName}",
                            $"OSRA terminated '{rule.ProcessName}' after it used its daily limit of {rule.DailyLimitMinutes} minutes.",
                            foregroundTitle);
                    }
                }
            }
            finally
            {
                foreach (var process in processes) process.Dispose();
            }
        }

        // 3. Blocklist pack apps (Feature #1): any running user process whose name is listed
        // in the downloaded pack under a blocked category is terminated like an AppRule "block"
        // entry. Alerts reuse the shared 5-min per-process throttle in SendAlertAsync.
        EnforceBlocklistApps(rules, foregroundTitle);

        if (!string.IsNullOrEmpty(foregroundTitle))
            _log.LogTrace("Foreground window: {Title}", foregroundTitle);
    }

    /// <summary>Feature #9: true when a paused agent must kill the process — never when
    /// always-allowed, never when not paused. Pure so the whole matrix is unit-testable.</summary>
    internal static bool ShouldKillWhenPaused(string processName, IReadOnlyCollection<string> allowed, bool paused)
    {
        if (!paused) return false;
        var name = RuleSetMapper.NormalizeProcessName(processName);
        if (name.Length == 0) return false;
        return !allowed.Any(a =>
            string.Equals(RuleSetMapper.NormalizeProcessName(a), name, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Kills every running user process not in the always-allowed list while paused (#9).</summary>
    private void EnforcePauseAllowlist(RuleSetSnapshot rules)
    {
        var selfId = Environment.ProcessId;
        Process[] all;
        try
        {
            all = Process.GetProcesses();
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Could not enumerate processes for the pause allowlist");
            return;
        }

        try
        {
            foreach (var process in all)
            {
                try
                {
                    if (process.Id == selfId || process.ProcessName.Length == 0) continue;
                    if (process.SessionId == 0) continue; // system/services session
                    var name = RuleSetMapper.NormalizeProcessName(process.ProcessName);
                    if (!ShouldKillWhenPaused(name, rules.AlwaysAllowedApps, paused: true)) continue;
                    // NOTE: kill attempts throttled to one per process name per 5 min (Android
                    // parity) so a supervisor restarting the app cannot cause a kill storm.
                    if (_pauseKillThrottle.TryGetValue(name, out var last) &&
                        DateTime.UtcNow - last < AlertThrottle)
                    {
                        continue;
                    }
                    process.Kill(entireProcessTree: true);
                    _pauseKillThrottle[name] = DateTime.UtcNow;
                    _log.LogInformation("Pause: terminated {Process} (not always-allowed)", process.ProcessName);
                }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "Could not terminate a process under the pause allowlist");
                }
            }
        }
        finally
        {
            foreach (var process in all) process.Dispose();
        }
    }

    /// <summary>Kills every running user process listed in blocklist_apps under a blocked category.</summary>
    private void EnforceBlocklistApps(RuleSetSnapshot rules, string? foregroundTitle)
    {
        var selfId = Environment.ProcessId;
        Process[] all;
        try
        {
            all = Process.GetProcesses();
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Could not enumerate processes for the blocklist app check");
            return;
        }

        try
        {
            foreach (var process in all)
            {
                try
                {
                    if (process.Id == selfId || process.ProcessName.Length == 0) continue;
                    if (process.SessionId == 0) continue; // system/services session
                    var category = _store.LookupAppCategory(process.ProcessName);
                    if (category is null) continue;
                    if (!rules.BlockedCategories.Contains(category, StringComparer.OrdinalIgnoreCase)) continue;
                    process.Kill(entireProcessTree: true);
                    _log.LogInformation("Blocklist: terminated {Process} (category {Category})", process.ProcessName, category);
                    _ = SendAlertAsync(process.ProcessName, "app_blocked",
                        $"Blocked app started: {process.ProcessName}",
                        $"OSRA terminated '{process.ProcessName}' (blocklist category '{category}').",
                        foregroundTitle);
                }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "Could not terminate a process under the blocklist app check");
                }
            }
        }
        finally
        {
            foreach (var process in all) process.Dispose();
        }
    }

    /// <summary>True when the process has used up its configured daily limit for today.</summary>
    private bool TimeLimitReached(AppRuleSnapshot rule)
    {
        if (rule.DailyLimitMinutes is not > 0) return false;
        var used = _store.MinutesUsedToday(rule.ProcessName) +
                   (int)(_accumulatedSeconds.GetValueOrDefault(rule.ProcessName) / 60);
        return used >= rule.DailyLimitMinutes.Value;
    }

    /// <summary>Kills every running process with the given name; returns how many were found.</summary>
    private int KillByName(string processName)
    {
        Process[] processes;
        try
        {
            processes = Process.GetProcessesByName(processName);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Could not enumerate processes for {Name}", processName);
            return 0;
        }

        try
        {
            KillAll(processes, processName);
            return processes.Length;
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
    }

    private void KillAll(Process[] processes, string processName)
    {
        foreach (var process in processes)
        {
            try
            {
                process.Kill(entireProcessTree: true);
                _log.LogInformation("Killed blocked process {Name} (pid {Pid})", processName, process.Id);
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Could not kill {Name} (pid {Pid})", processName, process.Id);
            }
        }
    }

    private async Task SendAlertAsync(string processName, string category, string title, string body, string? windowTitle)
    {
        if (_lastAlert.TryGetValue(processName, out var last) &&
            DateTime.UtcNow - last < AlertThrottle)
        {
            return; // NOTE: throttle kills to one alert per process per 5 min to avoid alert spam.
        }
        _lastAlert[processName] = DateTime.UtcNow;

        try
        {
            await _api.PostAlert(new AlertDto
            {
                DeviceId = _config.DeviceId,
                ChildId = _config.ChildId,
                Severity = "warning",
                Category = category,
                Title = title,
                Body = body,
                Metadata = new Dictionary<string, object>
                {
                    ["process"] = processName,
                    ["windowTitle"] = windowTitle ?? "",
                },
            });
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to post {Category} alert for {Name}", category, processName);
        }
    }

    /// <summary>Display label for the live foreground feed: the process name, or 'idle' when none (#29).</summary>
    internal static string ForegroundAppLabel(string? processName) =>
        string.IsNullOrEmpty(processName) ? "idle" : processName;

    /// <summary>Accumulates the 5 s foreground sample and flushes whole minutes to app_usage.</summary>
    private void AccumulateForegroundMinutes()
    {
        var seconds = _foregroundSeconds + PollInterval.TotalSeconds;
        if (seconds >= 60)
        {
            var minutes = (int)(seconds / 60);
            _store.AddAppMinutes(ForegroundAppLabel(LastForegroundProcess), minutes);
            seconds -= minutes * 60;
        }
        _foregroundSeconds = seconds;
    }

    private static string? GetForegroundProcessName()
    {
        try
        {
            var handle = GetForegroundWindow();
            if (handle == IntPtr.Zero) return null;
            // NOTE: P/Invoke GetWindowThreadProcessId (not Process enumeration) maps the
            // foreground hwnd to its owning pid; the process may exit before the name lookup.
            _ = GetWindowThreadProcessId(handle, out var pid);
            if (pid == 0) return null;
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (Exception)
        {
            return null;
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    private static string? GetForegroundWindowTitle()
    {
        try
        {
            var handle = GetForegroundWindow();
            if (handle == IntPtr.Zero) return null;
            var buffer = new StringBuilder(512);
            return GetWindowText(handle, buffer, buffer.Capacity) > 0 ? buffer.ToString() : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
}
