using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="TimeWindows"/>: half-open same-day windows, overnight
/// (wrap-midnight) windows, and routine day-of-week matching including previous-day crediting.
/// </summary>
public sealed class TimeWindowsTests
{
    private static DateTime At(DayOfWeek day, int hour, int minute = 0)
    {
        // 2026-09-14 is a Monday; step forward to the requested weekday.
        var monday = new DateTime(2026, 9, 14, hour, minute, 0);
        return monday.AddDays(((int)day - 1 + 7) % 7);
    }

    private static TimeOnly T(int hour, int minute = 0) => new(hour, minute);

    [Fact]
    public void SameDayWindowIsHalfOpen()
    {
        Assert.True(TimeWindows.IsInWindow(T(15, 0), T(15, 0), T(17, 0)));
        Assert.True(TimeWindows.IsInWindow(T(16, 30), T(15, 0), T(17, 0)));
        Assert.False(TimeWindows.IsInWindow(T(17, 0), T(15, 0), T(17, 0))); // end excluded
        Assert.False(TimeWindows.IsInWindow(T(14, 59), T(15, 0), T(17, 0)));
    }

    [Fact]
    public void OvernightWindowWrapsMidnight()
    {
        Assert.True(TimeWindows.IsInWindow(T(21, 0), T(21, 0), T(7, 0)));
        Assert.True(TimeWindows.IsInWindow(T(23, 59), T(21, 0), T(7, 0)));
        Assert.True(TimeWindows.IsInWindow(T(0, 0), T(21, 0), T(7, 0)));
        Assert.True(TimeWindows.IsInWindow(T(6, 59), T(21, 0), T(7, 0)));
        Assert.False(TimeWindows.IsInWindow(T(7, 0), T(21, 0), T(7, 0)));
        Assert.False(TimeWindows.IsInWindow(T(12, 0), T(21, 0), T(7, 0)));
    }

    [Fact]
    public void EmptyWindowNeverMatches()
    {
        Assert.False(TimeWindows.IsInWindow(T(10, 0), T(10, 0), T(10, 0)));
    }

    [Fact]
    public void RoutineMatchesOnlyOnListedDays()
    {
        var days = new HashSet<DayOfWeek> { DayOfWeek.Monday };
        Assert.True(TimeWindows.IsRoutineActive(At(DayOfWeek.Monday, 16), T(15), T(17), days));
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Tuesday, 16), T(15), T(17), days));
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Monday, 18), T(15), T(17), days));
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Monday, 14), T(15), T(17), days));
    }

    [Fact]
    public void OvernightRoutineCreditsTheEarlyMorningTailToTheStartDay()
    {
        var days = new HashSet<DayOfWeek> { DayOfWeek.Monday };
        // Window Monday 22:00 -> Tuesday 02:00.
        Assert.True(TimeWindows.IsRoutineActive(At(DayOfWeek.Monday, 22, 30), T(22), T(2), days));
        Assert.True(TimeWindows.IsRoutineActive(At(DayOfWeek.Tuesday, 1, 30), T(22), T(2), days));
        // The tail must NOT match when the previous day is not listed...
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Wednesday, 1, 30), T(22), T(2), days));
        // ...and the evening leg must NOT match on an unlisted day.
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Tuesday, 22, 30), T(22), T(2), days));
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Monday, 12, 0), T(22), T(2), days));
    }

    [Fact]
    public void OvernightRoutineSpanningSundayBoundary()
    {
        // Window starting Sunday 23:00 must still be active Monday 00:30.
        var days = new HashSet<DayOfWeek> { DayOfWeek.Sunday };
        Assert.True(TimeWindows.IsRoutineActive(At(DayOfWeek.Monday, 0, 30), T(23), T(1), days));
        Assert.False(TimeWindows.IsRoutineActive(At(DayOfWeek.Tuesday, 0, 30), T(23), T(1), days));
    }

    [Fact]
    public void EmptyDaysMeansEveryDay()
    {
        var days = new HashSet<DayOfWeek>();
        Assert.True(TimeWindows.IsRoutineActive(At(DayOfWeek.Saturday, 16), T(15), T(17), days));
        Assert.True(TimeWindows.IsRoutineActive(At(DayOfWeek.Wednesday, 1, 0), T(22), T(2), days));
    }
}
