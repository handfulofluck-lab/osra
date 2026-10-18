using System.Runtime.InteropServices;
using System.Text.Json;

namespace FamilyShield.Agent.Services;

/// <summary>Polls rule updates and pending device commands from the backend every 60 s.</summary>
public sealed class RuleSyncService : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(60);

    private readonly ILogger<RuleSyncService> _log;
    private readonly LocalRuleStore _store;
    private readonly ApiClient _api;
    private readonly AgentConfig _config;

    // Feature #22: at most one pending wind-down; a newer wind_down or an unlock cancels it.
    private CancellationTokenSource? _windDownCts;

    // Test seam: production shows the real LockOverlay; tests capture the call instead of
    // starting the WinForms message loop. Returns false when the overlay refused to arm.
    internal Func<string, string, string, bool> ShowOverlay = LockOverlay.ShowIfPinned;

    /// <summary>The last lock/pause/wind_down that was refused for want of a parent PIN, or null.</summary>
    internal string? LastArmRefusal { get; private set; }

    // internal so wind_down scheduling is unit-testable: tests substitute the delay instead of
    // waiting real minutes (NOTE: defaulting to Task.Delay keeps production behaviour).
    internal Func<TimeSpan, CancellationToken, Task> Delay = Task.Delay;

    // Feature #19/#20 test seams (same pattern as Delay): production defaults touch the registry /
    // status flag / NIC table; tests substitute fakes.
    internal Func<string, object?> ReadRegistryValue = TamperChecks.RegistryReader;
    internal Func<bool> ProxyRunningReader = () => AgentStatus.ProxyRunning;
    internal Func<IReadOnlyList<TamperChecks.VpnInterfaceInfo>> VpnInterfacesReader = TamperChecks.ListInterfaces;
    internal Action EnsureProxyEnforced = () => WebFilterProxy.EnsureSystemProxy();

    // Feature #19/#20: each alert family is throttled to one per hour so a persistent tamper
    // state cannot spam the parent; internal set so tests can rewind the throttle window.
    internal DateTime LastTamperAlertUtc { get; set; } = DateTime.MinValue;
    internal DateTime LastVpnAlertUtc { get; set; } = DateTime.MinValue;

    /// <summary>Creates the sync service.</summary>
    public RuleSyncService(ILogger<RuleSyncService> log, LocalRuleStore store, ApiClient api, AgentConfig config)
    {
        _log = log;
        _store = store;
        _api = api;
        _config = config;
    }

    /// <summary>Syncs rules and dispatches commands until the worker stops; failures are logged, never thrown.</summary>
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(PollInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try
                {
                    await Tick(stoppingToken);
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "RuleSyncService tick failed");
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    private async Task Tick(CancellationToken ct)
    {
        var childId = _config.ChildId;
        if (string.IsNullOrEmpty(childId))
        {
            _log.LogWarning("ChildId not configured; skipping rule sync");
        }
        else
        {
            var rules = await _api.GetRules(childId, ct);
            if (rules is not null)
            {
                _store.Sync(rules);
                _log.LogDebug("Rule set synced for child {ChildId}", childId);
            }
            else
            {
                _log.LogWarning("Rule sync returned no rule set for child {ChildId}", childId);
            }
        }

        // Feature #1: merge the real blocklist pack into the local block store every cycle,
        // right after the rule set. A failed fetch keeps the previously downloaded lists
        // (built-in starter domains remain the last-resort fallback).
        try
        {
            var pack = await _api.GetBlocklists(ct);
            if (pack is not null)
            {
                _store.SyncBlocklists(pack);
                _log.LogDebug("Blocklist pack v{Version} synced", pack.Version);
            }
            else
            {
                _log.LogWarning("Blocklist pack fetch failed; keeping existing lists");
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Blocklist sync failed");
        }

        var deviceId = _config.DeviceId;
        if (string.IsNullOrEmpty(deviceId))
        {
            _log.LogWarning("DeviceId not configured; skipping command poll");
            return;
        }

        foreach (var command in await _api.GetCommands(deviceId, ct))
        {
            Dispatch(command.Type, command.Payload);
        }

        // Feature #19/#20: tamper (proxy disabled) + VPN detection ride the same 60 s cadence.
        try
        {
            CheckTamperAndVpn();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Tamper/VPN check failed");
        }
    }

    /// <summary>
    /// One cadence pass of the Feature #19 tamper check and the Feature #20 VPN check; internal so
    /// the wiring (decision → throttled alert) is unit-testable without a 60 s timer.
    /// </summary>
    internal void CheckTamperAndVpn()
    {
        if (string.IsNullOrEmpty(_config.ChildId) || string.IsNullOrEmpty(_config.DeviceId)) return;

        // Feature #19: the agent proxy is running but the WinINET proxy is off or repointed —
        // the child disabled it in Windows settings.
        try
        {
            if (_config.SetSystemProxy)
            {
                var settings = TamperChecks.ReadProxySettings(ReadRegistryValue);
                if (TamperChecks.ShouldAlertProxyDisabled(ProxyRunningReader(), settings))
                {
                    // Re-enforce proxy automatically if disabled by child (WIN-06 self-healing)
                    EnsureProxyEnforced();

                    if ((DateTime.UtcNow - LastTamperAlertUtc) >= TimeSpan.FromHours(1))
                    {
                        LastTamperAlertUtc = DateTime.UtcNow;
                        _log.LogWarning("OSRA proxy disabled in Windows settings; re-enforced and raising tamper alert");
                        _ = _api.PostAlert(new AlertDto
                        {
                            ChildId = _config.ChildId,
                            DeviceId = _config.DeviceId,
                            Severity = "critical",
                            Category = "tamper",
                            Title = "Web filter was bypassed",
                            Body = "The OSRA proxy was disabled in Windows settings",
                            Metadata = new Dictionary<string, object> { ["type"] = "proxy_disabled" },
                        });
                    }
                }
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Proxy tamper check failed");
        }

        // Feature #20: an up tap/tun/wireguard interface means a VPN tunnel may route traffic
        // around the filter (HTTPS would then bypass the proxy entirely).
        try
        {
            foreach (var ni in VpnInterfacesReader())
            {
                if (!ni.IsUp || !TamperChecks.LooksLikeVpn(ni.Name, ni.Description)) continue;
                if ((DateTime.UtcNow - LastVpnAlertUtc) < TimeSpan.FromHours(1)) break;
                LastVpnAlertUtc = DateTime.UtcNow;
                _log.LogWarning("VPN tunnel interface active: {Name}; raising vpn_detected alert", ni.Name);
                _ = _api.PostAlert(new AlertDto
                {
                    ChildId = _config.ChildId,
                    DeviceId = _config.DeviceId,
                    Severity = "warning",
                    Category = "vpn_detected",
                    Title = "VPN active",
                    Body = "A VPN tunnel may be routing traffic around the filter",
                    Metadata = new Dictionary<string, object> { ["type"] = "vpn_interface", ["interface"] = ni.Name },
                });
                break;
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "VPN detection check failed");
        }
    }

    // NOTE: acking is handled server-side (commands are consumed by this GET), so no ack call is made here.
    // internal so the command→action mapping (Feature #11 pause/resume, #10 bonus_time, #22 wind_down)
    // is unit-testable.
    internal void Dispatch(string? type, JsonElement? payload = null)
    {
        switch (type)
        {
            case "pause_internet":
                // Feature #11: sinkhole all web traffic at the proxy except allowedDomains.
                _log.LogInformation("Command: pause_internet");
                _store.SetPaused(true);
                break;
            case "resume_internet":
                _log.LogInformation("Command: resume_internet");
                _store.SetPaused(false);
                break;
            case "lock":
                // Agent-owned overlay (not LockWorkStation) so the parent's Unlock command
                // can actually dismiss it; the child cannot bypass it without the PIN.
                // Audit finding 1: no PIN means no restriction — refuse rather than use a default.
                _log.LogInformation("Command: lock");
                if (TryGetParentPin("lock", out var lockPin))
                {
                    ShowOverlay(lockPin, "OSRA — Locked",
                        "This PC was locked by a parent. Ask a parent to enter the PIN.");
                }
                break;
            case "unlock":
                _log.LogInformation("Command: unlock");
                CancelWindDown();
                LockOverlay.Hide();
                break;
            case "pause":
                // Same overlay mechanics as lock with paused messaging; resumable via "resume".
                _log.LogInformation("Command: pause");
                if (TryGetParentPin("pause", out var pausePin))
                {
                    ShowOverlay(pausePin, "OSRA — Paused",
                        "This PC was paused by a parent. Ask a parent to resume it or enter the PIN.");
                }
                break;
            case "resume":
                _log.LogInformation("Command: resume");
                LockOverlay.Hide();
                break;
            case "ring":
                _log.LogInformation("Command: ring");
                // NOTE: beeping takes ~5 s; run it off the poll loop so command dispatch isn't stalled.
                _ = Task.Run(Ring);
                break;
            case "sos_clear":
                // NOTE: SOS state lives server-side; there is no local SOS UI to clear on desktop.
                _log.LogInformation("Command: sos_clear (no-op locally)");
                break;
            case "bonus_time":
                // Feature #10: grant N extra screen-time minutes for today only. The rules
                // payload republished by the API carries the same total (bonusMinutesToday);
                // the local counter makes the grant durable immediately, without waiting for
                // the next 60 s rule poll.
                if (ParseMinutes(payload) is > 0 and var bonus)
                {
                    _log.LogInformation("Command: bonus_time +{Minutes} min", bonus);
                    _store.AddBonusMinutes(bonus);
                }
                else
                {
                    _log.LogWarning("Command: bonus_time with missing/invalid minutes; ignored");
                }
                break;
            case "wind_down":
                // Feature #22: warn now (log heads-up — desktop has no notification center
                // dependency), then lock after N minutes. A newer wind_down replaces the
                // pending one and unlock cancels it. Refused without a parent PIN, because the
                // lock it ends in must be dismissable only by that PIN.
                var windDown = ParseMinutes(payload);
                if (windDown <= 0)
                {
                    _log.LogWarning("Command: wind_down with missing/invalid minutes; ignored");
                }
                else if (TryGetParentPin("wind_down", out _))
                {
                    _log.LogInformation("Command: wind_down; screen will lock in {Minutes} min", windDown);
                    _windDownCts?.Cancel();
                    _windDownCts?.Dispose();
                    var cts = new CancellationTokenSource();
                    _windDownCts = cts;
                    _ = WindDownAfterAsync(TimeSpan.FromMinutes(windDown), cts.Token);
                }
                break;
            case "rules_updated":
                _log.LogInformation("Command: rules_updated; re-syncing");
                _ = RefreshRulesAsync();
                break;
            default:
                _log.LogWarning("Unknown device command: {Type}", type);
                break;
        }
    }

    /// <summary>Parses payload.minutes; tolerates a JSON number or a numeric string (poll stringifies).</summary>
    private static int ParseMinutes(JsonElement? payload)
    {
        if (payload is not { ValueKind: JsonValueKind.Object } element ||
            !element.TryGetProperty("minutes", out var minutes)) return 0;
        return minutes.ValueKind switch
        {
            JsonValueKind.Number when minutes.TryGetInt32(out var n) => n,
            JsonValueKind.String when int.TryParse(minutes.GetString(), out var s) => s,
            _ => 0,
        };
    }

    /// <summary>
    /// Resolves the configured parent PIN for an arming action. With none configured the action is
    /// refused and logged at error level (audit finding 1: never fall back to a default PIN).
    /// </summary>
    private bool TryGetParentPin(string action, out string pin)
    {
        var configured = ParentPinPolicy.Normalize(_config.ParentPin);
        if (configured is not null)
        {
            pin = configured;
            LastArmRefusal = null;
            return true;
        }

        pin = string.Empty;
        LastArmRefusal = action;
        _log.LogError(
            "Refusing to {Action}: no parent PIN is configured. Set parentPin in {Config} to a {Min}-{Max} " +
            "digit PIN, or set DESKTOP_PARENT_PIN and restart once; OSRA does not use a default PIN.",
            action, AgentConfig.FileName, ParentPinPolicy.MinLength, ParentPinPolicy.MaxLength);
        return false;
    }

    private void CancelWindDown()
    {
        _windDownCts?.Cancel();
        _windDownCts?.Dispose();
        _windDownCts = null;
    }

    private async Task WindDownAfterAsync(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Delay(delay, ct);
        }
        catch (OperationCanceledException)
        {
            return; // superseded by a newer wind_down or cancelled by unlock
        }
        _log.LogInformation("Wind-down elapsed; locking the screen");
        if (TryGetParentPin("wind_down", out var pin))
        {
            ShowOverlay(pin, "OSRA", "Wind-down: screen locked.");
        }
    }

    private async Task RefreshRulesAsync()
    {
        try
        {
            var childId = _config.ChildId;
            if (string.IsNullOrEmpty(childId)) return;
            var rules = await _api.GetRules(childId);
            if (rules is not null) _store.Sync(rules);
            var pack = await _api.GetBlocklists();
            if (pack is not null) _store.SyncBlocklists(pack);
            else _log.LogWarning("Blocklist pack fetch failed during rules_updated; keeping existing lists");
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "rules_updated re-sync failed");
        }
    }

    // NOTE: simplest possible ring — console beeps for ~5 s; no WAV file is shipped with the agent.
    private static void Ring()
    {
        for (var i = 0; i < 5; i++)
        {
            try
            {
                Console.Beep(880, 400);
            }
            catch (Exception)
            {
                // no audio device; ignore
            }
            Thread.Sleep(600);
        }
    }
}
