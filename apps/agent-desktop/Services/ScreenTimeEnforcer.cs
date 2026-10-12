using System.Runtime.InteropServices;

namespace FamilyShield.Agent.Services;

/// <summary>Enforces the daily screen-time budget (topmost overlay) and the bedtime window (workstation lock).</summary>
public sealed class ScreenTimeEnforcer : BackgroundService
{
    private static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(60);
    private static readonly string ParentPin =
        Environment.GetEnvironmentVariable("DESKTOP_PARENT_PIN") ?? "0000";

    private readonly ILogger<ScreenTimeEnforcer> _log;
    private readonly LocalRuleStore _store;

    /// <summary>Creates the enforcer.</summary>
    public ScreenTimeEnforcer(ILogger<ScreenTimeEnforcer> log, LocalRuleStore store)
    {
        _log = log;
        _store = store;
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

    private void Evaluate()
    {
        var rules = _store.Current;
        if (rules is null) return;

        var now = DateTime.Now;

        // Bedtime enforcement (WIN-02): lock workstation AND assert agent-owned PIN overlay
        var inBedtime = rules.BedtimeStart is { } bedtimeStart && rules.BedtimeEnd is { } bedtimeEnd &&
            TimeWindows.IsInWindow(TimeOnly.FromDateTime(now), bedtimeStart, bedtimeEnd);

        if (inBedtime)
        {
            _log.LogInformation("Bedtime window active ({Start}-{End}); locking workstation and asserting PIN overlay",
                rules.BedtimeStart, rules.BedtimeEnd);
            LockWorkStation();
            LockOverlay.Show(ParentPin, "OSRA",
                "Bedtime active. Ask a parent to enter the PIN to unlock.");
            return;
        }

        var limit = EffectiveLimit(rules, now.DayOfWeek);
        if (limit <= 0)
        {
            LockOverlay.Hide();
            return; // NOTE: limit <= 0 means "no daily cap configured".
        }

        var used = _store.MinutesUsedToday();
        if (used >= limit)
        {
            _log.LogInformation("Screen-time limit reached: {Used}/{Limit} minutes; showing PIN overlay", used, limit);
            LockOverlay.Show(ParentPin, "OSRA",
                "Screen time limit reached. Ask a parent to enter the PIN.");
        }
        else
        {
            LockOverlay.Hide();
        }
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
