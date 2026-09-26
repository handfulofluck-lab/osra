using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for the ScreenTimeEnforcer effective-limit math (Feature #10): the
/// weekday/weekend base limit plus the bonus minutes carried by the rules payload
/// (bonusMinutesToday, mapped in <see cref="RuleSetMapper"/>).
/// </summary>
public sealed class ScreenTimeEnforcerTests
{
    private static RuleSetSnapshot Rules(int daily, int? weekend = null, int bonus = 0) =>
        RuleSetMapper.FromDto(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = daily, WeekendLimitMinutes = weekend },
            BonusMinutesToday = bonus,
        });

    [Fact]
    public void WeekdayLimitIncludesBonus()
    {
        Assert.Equal(150, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 300, 30), DayOfWeek.Monday));
        Assert.Equal(150, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 300, 30), DayOfWeek.Friday));
    }

    [Fact]
    public void WeekendOverrideLimitIncludesBonus()
    {
        Assert.Equal(330, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 300, 30), DayOfWeek.Saturday));
        Assert.Equal(330, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 300, 30), DayOfWeek.Sunday));
    }

    [Fact]
    public void WeekendFallsBackToDailyPlusBonus()
    {
        Assert.Equal(150, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 0, 30), DayOfWeek.Saturday));
    }

    [Fact]
    public void MissingBonusFieldAddsNothing()
    {
        Assert.Equal(120, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 300), DayOfWeek.Monday));
        Assert.Equal(300, ScreenTimeEnforcer.EffectiveLimit(Rules(120, 300), DayOfWeek.Saturday));
    }
}
