using System.Runtime.InteropServices;

namespace FamilyShield.Agent.Services;

/// <summary>Enforces the daily screen-time budget (topmost overlay) and the bedtime window (workstation lock).</summary>
public sealed class ScreenTimeEnforcer : BackgroundService
{
    private static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(60);

    private readonly ILogger<ScreenTimeEnforcer> _log;
    private readonly LocalRuleStore _store;
    private readonly AgentConfig _config;
    private bool _pinRefusalLogged;

    // Test seams: production shows/hides the real overlay; tests capture the calls instead of
    // starting the WinForms message loop. ShowOverlay returns false when it refused to arm.
    internal Func<string, string, string, bool> ShowOverlay = LockOverlay.ShowIfPinned;
    internal Action HideOverlay = LockOverlay.Hide;

    // Test seam: tests must never lock the developer's real Windows session.
    internal Action LockWorkstationAction = () => LockWorkStation();

    /// <summary>The last action refused for want of a parent PIN, or null.</summary>
    internal string? LastArmRefusal { get; private set; }

    /// <summary>Creates the enforcer.</summary>
    public ScreenTimeEnforcer(ILogger<ScreenTimeEnforcer> log, LocalRuleStore store, AgentConfig config)
    {
        _log = log;
        _store = store;
        _config = config;
    }

    /// <summary>Evaluates the rule set every 60 s until the worker stops; failures are logged, never thrown.</summary>
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            using var timer = new PeriodicTimer(CheckInterval);
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try
                {
                    Evaluate();
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "ScreenTimeEnforcer evaluation failed");
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "ScreenTimeEnforcer failed unexpectedly");
        }
    }

    private void Evaluate() => Evaluate(DateTime.Now);

    /// <summary>
    /// One enforcement pass at <paramref name="now"/>; internal so the gate is testable without
    /// waiting for the 60 s timer.
    /// </summary>
    internal void Evaluate(DateTime now)
    {
        if (!TryGetParentPin(out var pin))
        {
            // Audit finding 1: with no PIN there is nothing that only a parent can dismiss, so a
            // bedtime/screen-time lock must not arm. Clear any overlay left from an earlier PIN.
            HideOverlay();
            return;
        }

        var rules = _store.Current;
        if (rules is null) return;

        // Bedtime enforcement (WIN-02): lock workstation AND assert agent-owned PIN overlay
        var inBedtime = rules.BedtimeStart is { } bedtimeStart && rules.BedtimeEnd is { } bedtimeEnd &&
            TimeWindows.IsInWindow(TimeOnly.FromDateTime(now), bedtimeStart, bedtimeEnd);

        if (inBedtime)
        {
            _log.LogInformation("Bedtime window active ({Start}-{End}); locking workstation and asserting PIN overlay",
                rules.BedtimeStart, rules.BedtimeEnd);
            LockWorkstationAction();
            ShowOverlay(pin, "OSRA",
                "Bedtime active. Ask a parent to enter the PIN to unlock.");
            return;
        }

        var limit = EffectiveLimit(rules, now.DayOfWeek);
        if (limit <= 0)
        {
            HideOverlay();
            return; // NOTE: limit <= 0 means "no daily cap configured".
        }

        var used = _store.MinutesUsedToday();
        if (used >= limit)
        {
            _log.LogInformation("Screen-time limit reached: {Used}/{Limit} minutes; showing PIN overlay", used, limit);
            ShowOverlay(pin, "OSRA",
                "Screen time limit reached. Ask a parent to enter the PIN.");
        }
        else
        {
            HideOverlay();
        }
    }

    /// <summary>
    /// Resolves the per-install parent PIN; a missing PIN refuses to arm and is logged once per
    /// run (not once per 60 s tick) so the reason is visible without flooding the console.
    /// </summary>
    private bool TryGetParentPin(out string pin)
    {
        var configured = ParentPinPolicy.Normalize(_config.ParentPin);
        if (configured is not null)
        {
            pin = configured;
            LastArmRefusal = null;
            _pinRefusalLogged = false;
            return true;
        }

        pin = string.Empty;
        LastArmRefusal = "screen_time";
        if (!_pinRefusalLogged)
        {
            _pinRefusalLogged = true;
            _log.LogError(
                "Refusing to arm bedtime/screen-time: no parent PIN is configured. Set parentPin in {Config} " +
                "to a {Min}-{Max} digit PIN, or set DESKTOP_PARENT_PIN and restart once; OSRA does not use a default PIN.",
                AgentConfig.FileName, ParentPinPolicy.MinLength, ParentPinPolicy.MaxLength);
        }
        return false;
    }

    /// <summary>
    /// Effective daily cap for <paramref name="day"/>: the weekday/weekend base limit plus the
    /// bonus minutes granted today (Feature #10). The API republishes the rules payload with
    /// the running bonusMinutesToday total on every grant, so the 60 s rule poll picks grants
    /// up within one cycle. internal so the limit math is unit-testable.
    /// </summary>
    internal static int EffectiveLimit(RuleSetSnapshot rules, DayOfWeek day) =>
        rules.EffectiveDailyLimit(day) + Math.Max(0, rules.BonusMinutesToday);

    [DllImport("user32.dll")]
    private static extern bool LockWorkStation();
}
