using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="RuleSetMapper"/> and <see cref="RuleSetSnapshot"/>: process-name
/// normalization, routine mapping (day encoding, window parsing), the weekend limit switch and
/// ActiveRoutineBlockedApps.
/// </summary>
public sealed class RuleSetMapperTests
{
    private static DateTime At(DayOfWeek day, int hour, int minute = 0)
    {
        // 2026-09-14 is a Monday; step forward to the requested weekday.
        var monday = new DateTime(2026, 9, 14, hour, minute, 0);
        return monday.AddDays(((int)day - 1 + 7) % 7);
    }

    [Theory]
    [InlineData("Game.exe", "game")]
    [InlineData("GAME.EXE", "game")]
    [InlineData(" minecraft ", "minecraft")]
    [InlineData("chrome", "chrome")]
    public void NormalizeProcessNameStripsExeAndLowercases(string input, string expected) =>
        Assert.Equal(expected, RuleSetMapper.NormalizeProcessName(input));

    [Fact]
    public void AppRulesAreNormalized()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            AppRules =
            [
                new AppRuleDto { PackageId = "Game.EXE", AppName = "Game", Action = "BLOCK", DailyLimitMinutes = 0 },
                new AppRuleDto { PackageId = " ", AppName = "ignored" },
                new AppRuleDto { PackageId = "browser", Action = null },
            ],
        });

        Assert.Equal(2, snapshot.AppRules.Count);
        Assert.Equal("game", snapshot.AppRules[0].ProcessName);
        Assert.Equal("block", snapshot.AppRules[0].Action);
        Assert.Null(snapshot.AppRules[0].DailyLimitMinutes); // 0/negative means "no limit"
        Assert.Equal("allow", snapshot.AppRules[1].Action); // missing action defaults to allow
    }

    [Fact]
    public void WeekendLimitSwitchFollowsTheWeekday()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = 120, WeekendLimitMinutes = 300 },
        });
        Assert.Equal(120, snapshot.EffectiveDailyLimit(DayOfWeek.Monday));
        Assert.Equal(120, snapshot.EffectiveDailyLimit(DayOfWeek.Friday));
        Assert.Equal(300, snapshot.EffectiveDailyLimit(DayOfWeek.Saturday));
        Assert.Equal(300, snapshot.EffectiveDailyLimit(DayOfWeek.Sunday));
    }

    [Fact]
    public void WeekendLimitFallsBackToDailyWhenNotPositive()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = 120, WeekendLimitMinutes = 0 },
        });
        Assert.Null(snapshot.WeekendLimitMinutes);
        Assert.Equal(120, snapshot.EffectiveDailyLimit(DayOfWeek.Saturday));
    }

    [Fact]
    public void RoutinesAreMappedWithNormalizedAppsAndDays()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            Routines =
            [
                new RoutineDto
                {
                    Name = "Homework",
                    StartTime = "15:00",
                    EndTime = "17:00",
                    Days = [1], // Monday (ISO)
                    BlockedApps = ["Game.EXE", "chat"],
                },
            ],
        });

        var routine = Assert.Single(snapshot.Routines);
        Assert.Equal("Homework", routine.Name);
        Assert.Equal(new TimeOnly(15, 0), routine.StartTime);
        Assert.Equal(new TimeOnly(17, 0), routine.EndTime);
        Assert.Equal([DayOfWeek.Monday], routine.Days);
        Assert.Equal(["game", "chat"], routine.BlockedApps);
    }

    [Theory]
    [InlineData(1, DayOfWeek.Monday)]
    [InlineData(5, DayOfWeek.Friday)]
    [InlineData(6, DayOfWeek.Saturday)]
    [InlineData(7, DayOfWeek.Sunday)] // ISO Sunday
    [InlineData(0, DayOfWeek.Sunday)] // JS-style Sunday also accepted by the API schema
    public void RoutineDayNumbersMapToWeekdays(int dayNumber, DayOfWeek expected)
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            Routines = [new RoutineDto { Name = "r", StartTime = "10:00", EndTime = "11:00", Days = [dayNumber] }],
        });
        Assert.Equal([expected], Assert.Single(snapshot.Routines).Days);
    }

    [Theory]
    [InlineData("15:00", "15:00")] // empty window
    [InlineData("not-a-time", "17:00")] // unparsable start
    [InlineData("15:00", null)] // missing end
    public void UnenforceableRoutinesAreDropped(string? start, string? end)
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            Routines = [new RoutineDto { Name = "broken", StartTime = start, EndTime = end, BlockedApps = ["game"] }],
        });
        Assert.Empty(snapshot.Routines);
    }

    [Fact]
    public void BonusAndAlwaysAllowedAppsAreMappedFromTopLevelWireFields()
    {
        const string json = """
            {"screenTime":{"dailyLimitMinutes":120},"bonusMinutesToday":30,"alwaysAllowedApps":["chrome.exe","Calculator"]}
            """;
        var dto = JsonSerializer.Deserialize<RuleSetDto>(json, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        Assert.NotNull(dto);
        var snapshot = RuleSetMapper.FromDto(dto!);
        Assert.Equal(30, snapshot.BonusMinutesToday);
        Assert.Equal(["chrome", "calculator"], snapshot.AlwaysAllowedApps);
    }

    [Fact]
    public void MissingBonusFieldsDefaultToZeroAndEmpty()
    {
        // Older servers / parents that never granted bonus may omit both fields entirely.
        const string json = """{"screenTime":{"dailyLimitMinutes":60}}""";
        var dto = JsonSerializer.Deserialize<RuleSetDto>(json, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        Assert.NotNull(dto);
        var snapshot = RuleSetMapper.FromDto(dto!);
        Assert.Equal(0, snapshot.BonusMinutesToday);
        Assert.Empty(snapshot.AlwaysAllowedApps);
    }

    [Fact]
    public void NegativeBonusMinutesAreClampedToZero()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = 60 },
            BonusMinutesToday = -15,
        });
        Assert.Equal(0, snapshot.BonusMinutesToday);
    }

    [Fact]
    public void BonusFieldsSurviveJsonRoundTrip()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = 60 },
            BonusMinutesToday = 45,
            AlwaysAllowedApps = ["chrome.exe"],
        });

        var restored = RuleSetMapper.FromJson(RuleSetMapper.ToJson(snapshot));
        Assert.NotNull(restored);
        Assert.Equal(45, restored!.BonusMinutesToday);
        Assert.Equal(["chrome"], restored.AlwaysAllowedApps);
    }

    [Fact]
    public void ActiveRoutineBlockedAppsReflectsTheWindow()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            Routines =
            [
                new RoutineDto
                {
                    Name = "Homework",
                    StartTime = "15:00",
                    EndTime = "17:00",
                    Days = [1], // Monday
                    BlockedApps = ["game.exe"],
                },
            ],
        });

        Assert.Equal(["game"], snapshot.ActiveRoutineBlockedApps(At(DayOfWeek.Monday, 16)));
        Assert.Empty(snapshot.ActiveRoutineBlockedApps(At(DayOfWeek.Monday, 18)));
        Assert.Empty(snapshot.ActiveRoutineBlockedApps(At(DayOfWeek.Tuesday, 16)));
    }

    [Fact]
    public void ActiveRoutineAllowedAppsDrivesAllowlistMode()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            Routines =
            [
                new RoutineDto
                {
                    Name = "Homework",
                    StartTime = "15:00",
                    EndTime = "17:00",
                    Days = [1], // Monday
                    AllowedApps = ["notepad.exe"],
                },
                new RoutineDto
                {
                    Name = "Bedtime",
                    StartTime = "21:00",
                    EndTime = "07:00",
                    Days = [1],
                    AllowedApps = [],
                },
            ],
        });

        // Active window with a non-empty allowlist → only those processes may run.
        Assert.Equal(["notepad"], snapshot.ActiveRoutineAllowedApps(At(DayOfWeek.Monday, 16)));
        // Inactive window and empty-allowlist windows contribute nothing.
        Assert.Empty(snapshot.ActiveRoutineAllowedApps(At(DayOfWeek.Monday, 18)));
        Assert.Empty(snapshot.ActiveRoutineAllowedApps(At(DayOfWeek.Monday, 22)));
    }

    [Fact]
    public void SnapshotSurvivesJsonRoundTrip()
    {
        var snapshot = RuleSetMapper.FromDto(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = 90, BedtimeStart = "21:00", BedtimeEnd = "07:00" },
            Routines =
            [
                new RoutineDto { Name = "Bed", StartTime = "20:00", EndTime = "06:00", Days = [7], BlockedApps = ["game"] },
            ],
        });

        var restored = RuleSetMapper.FromJson(RuleSetMapper.ToJson(snapshot));
        Assert.NotNull(restored);
        Assert.Equal(90, restored.DailyLimitMinutes);
        var routine = Assert.Single(restored.Routines);
        Assert.Equal("Bed", routine.Name);
        Assert.Equal([DayOfWeek.Sunday], routine.Days);
        Assert.Equal(["game"], routine.BlockedApps);
        Assert.Equal(["game"], restored.ActiveRoutineBlockedApps(At(DayOfWeek.Sunday, 21)));
    }
}
