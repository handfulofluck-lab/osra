namespace FamilyShield.Agent.Services;

/// <summary>
/// Pure time-window math shared by the screen-time enforcer (bedtime) and routine evaluation.
/// Kept free of I/O so the logic is unit-testable; semantics match the Android RuleEngine.
/// </summary>
public static class TimeWindows
{
    /// <summary>
    /// True when <paramref name="now"/> is inside [start, end). Windows with start &gt; end wrap
    /// midnight (e.g. bedtime 21:00-07:00); start == end is an empty (never active) window.
    /// </summary>
    public static bool IsInWindow(TimeOnly now, TimeOnly start, TimeOnly end) =>
        start <= end
            ? now >= start && now < end
            : now >= start || now < end;

    /// <summary>
    /// True when a routine with the given window and start-days is active at
    /// <paramref name="localNow"/>. Overnight windows (start &gt; end) are credited to the day they
    /// start on: the evening leg requires today to be a listed day, the early-morning tail
    /// requires yesterday. An empty <paramref name="days"/> set means the window runs every day.
    /// </summary>
    public static bool IsRoutineActive(DateTime localNow, TimeOnly start, TimeOnly end, IReadOnlyCollection<DayOfWeek> days)
    {
        var time = TimeOnly.FromDateTime(localNow);
        if (start <= end)
        {
            return DayMatches(days, localNow.DayOfWeek) && IsInWindow(time, start, end);
        }

        // Overnight window: split at midnight and credit each leg to the day it falls on.
        if (time >= start) return DayMatches(days, localNow.DayOfWeek);
        if (time < end) return DayMatches(days, PreviousDay(localNow.DayOfWeek));
        return false;
    }

    private static bool DayMatches(IReadOnlyCollection<DayOfWeek> days, DayOfWeek day) =>
        days.Count == 0 || days.Contains(day);

    private static DayOfWeek PreviousDay(DayOfWeek day) => (DayOfWeek)(((int)day + 6) % 7);
}
