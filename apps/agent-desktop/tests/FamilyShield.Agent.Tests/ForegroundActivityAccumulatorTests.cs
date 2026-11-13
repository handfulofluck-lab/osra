using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class ForegroundActivityAccumulatorTests : IDisposable
{
    private readonly string _dir;
    private readonly LocalRuleStore _store;
    private readonly ForegroundActivityAccumulator _accumulator;

    public ForegroundActivityAccumulatorTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "osra-foreground-tests", Guid.NewGuid().ToString("N"));
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, Path.Combine(_dir, "agent.db"), Path.Combine(_dir, "status.json"));
        _accumulator = new ForegroundActivityAccumulator(_store);
    }

    [Fact]
    public void ValidSamplesAccumulateWholeMinutesAndIdleDoesNotCount()
    {
        var start = new DateTime(2026, 11, 13, 12, 0, 0, DateTimeKind.Utc);
        for (var i = 0; i < 12; i++) _accumulator.AddSample(7, "demo", start.AddSeconds(i * 5));
        _accumulator.AddSample(7, "LockApp", start.AddSeconds(80));
        _accumulator.AddSample(7, "LogonUI", start.AddSeconds(100));

        var batch = _store.GetUnuploadedTelemetry();
        var row = Assert.Single(batch.AppUsage);
        Assert.Equal("demo", row.Process);
        Assert.Equal(1, row.Minutes);
    }

    [Fact]
    public void IdleAndUnknownSamplesAccumulateNothing()
    {
        var start = new DateTime(2026, 11, 13, 12, 0, 0, DateTimeKind.Utc);
        for (var i = 0; i < 12; i++) _accumulator.AddSample(7, "LockApp", start.AddSeconds(i * 5));
        _accumulator.AddSample(7, "", start.AddSeconds(100));
        _accumulator.AddSample(7, "LogonUI", start.AddSeconds(105));
        Assert.Empty(_store.GetUnuploadedTelemetry().AppUsage);
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch (Exception) { }
    }
}
