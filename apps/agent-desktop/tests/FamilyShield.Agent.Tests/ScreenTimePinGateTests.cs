using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Tests for the desktop audit finding 1 gate in <see cref="ScreenTimeEnforcer"/>: without a
/// per-install parent PIN, bedtime and the daily screen-time cap refuse to arm; with one, the
/// overlay carries exactly that PIN and the workstation lock still happens at bedtime.
/// </summary>
public sealed class ScreenTimePinGateTests : IDisposable
{
    private readonly string _dir;
    private readonly LocalRuleStore _store;

    public ScreenTimePinGateTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"));
        _store = new LocalRuleStore(
            NullLogger<LocalRuleStore>.Instance,
            Path.Combine(_dir, "agent.db"),
            Path.Combine(_dir, "status.json"));
    }

    private sealed class Observed
    {
        public List<string> ShownPins { get; } = [];
        public int Hidden { get; set; }
        public int WorkstationLocks { get; set; }
    }

    private ScreenTimeEnforcer Enforcer(string? parentPin, Observed observed)
    {
        var enforcer = new ScreenTimeEnforcer(
            NullLogger<ScreenTimeEnforcer>.Instance, _store, new AgentConfig { ParentPin = parentPin });
        enforcer.ShowOverlay = (pin, _, _) =>
        {
            observed.ShownPins.Add(pin);
            return true;
        };
        enforcer.HideOverlay = () => observed.Hidden++;
        // The real LockWorkStation would lock the developer's Windows session.
        enforcer.LockWorkstationAction = () => observed.WorkstationLocks++;
        return enforcer;
    }

    private static readonly DateTime BedtimeNow = new(2026, 10, 18, 22, 0, 0);
    private static readonly DateTime DaytimeNow = new(2026, 10, 18, 12, 0, 0);

    private void SyncRules(int dailyLimitMinutes = 60, string? bedtimeStart = null, string? bedtimeEnd = null) =>
        _store.Sync(new RuleSetDto
        {
            ScreenTime = new ScreenTimeRuleDto
            {
                DailyLimitMinutes = dailyLimitMinutes,
                BedtimeStart = bedtimeStart,
                BedtimeEnd = bedtimeEnd,
            },
        });

    [Fact]
    public void BedtimeRefusesToArmWithoutAParentPin()
    {
        SyncRules(bedtimeStart: "21:00", bedtimeEnd: "07:00");
        var observed = new Observed();
        var enforcer = Enforcer(null, observed);

        enforcer.Evaluate(BedtimeNow);

        Assert.Empty(observed.ShownPins);
        Assert.Equal(0, observed.WorkstationLocks);
        Assert.True(observed.Hidden >= 1);
        Assert.Equal("screen_time", enforcer.LastArmRefusal);
    }

    [Fact]
    public void BedtimeArmsWithTheConfiguredPin()
    {
        SyncRules(bedtimeStart: "21:00", bedtimeEnd: "07:00");
        var observed = new Observed();
        var enforcer = Enforcer("4821", observed);

        enforcer.Evaluate(BedtimeNow);

        Assert.Equal("4821", Assert.Single(observed.ShownPins));
        Assert.Equal(1, observed.WorkstationLocks);
        Assert.Null(enforcer.LastArmRefusal);
    }

    [Fact]
    public void LegacyDefaultPinDoesNotArmBedtime()
    {
        SyncRules(bedtimeStart: "21:00", bedtimeEnd: "07:00");
        var observed = new Observed();
        var enforcer = Enforcer(ParentPinPolicy.LegacyDefault, observed);

        enforcer.Evaluate(BedtimeNow);

        Assert.Empty(observed.ShownPins);
        Assert.Equal(0, observed.WorkstationLocks);
        Assert.Equal("screen_time", enforcer.LastArmRefusal);
    }

    [Fact]
    public void ScreenTimeCapRefusesToArmWithoutAParentPin()
    {
        SyncRules(dailyLimitMinutes: 60);
        _store.AddAppMinutes("chrome", 90);
        var observed = new Observed();
        var enforcer = Enforcer(null, observed);

        enforcer.Evaluate(DaytimeNow);

        Assert.Empty(observed.ShownPins);
        Assert.Equal("screen_time", enforcer.LastArmRefusal);
    }

    [Fact]
    public void ScreenTimeCapArmsWithTheConfiguredPin()
    {
        SyncRules(dailyLimitMinutes: 60);
        _store.AddAppMinutes("chrome", 90);
        var observed = new Observed();
        var enforcer = Enforcer("4821", observed);

        enforcer.Evaluate(DaytimeNow);

        Assert.Equal("4821", Assert.Single(observed.ShownPins));
        Assert.Null(enforcer.LastArmRefusal);
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch (Exception) { }
    }
}
