using System.Text.Json;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for the RuleSyncService command-dispatch mapping: pause_internet / resume_internet
/// (Feature #11), bonus_time (Feature #10) and wind_down (Feature #22, injectable delay seam).
/// Dispatch is internal (InternalsVisibleTo) so the mapping is testable without a server.
/// </summary>
public sealed class RuleSyncDispatchTests : IDisposable
{
    private readonly string _dbPath;
    private readonly string _statusPath;
    private readonly LocalRuleStore _store;
    private readonly RuleSyncService _sync;

    public RuleSyncDispatchTests()
    {
        var dir = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"));
        _dbPath = Path.Combine(dir, "agent.db");
        _statusPath = Path.Combine(dir, "status.json");
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, _dbPath, _statusPath);
        var api = new ApiClient(new HttpClient(), new AgentConfig());
        _sync = new RuleSyncService(NullLogger<RuleSyncService>.Instance, _store, api, new AgentConfig());
    }

    [Fact]
    public void PauseInternetSetsThePauseFlag()
    {
        Assert.False(_store.Paused);
        _sync.Dispatch("pause_internet");
        Assert.True(_store.Paused);
    }

    [Fact]
    public void ResumeInternetClearsThePauseFlag()
    {
        _sync.Dispatch("pause_internet");
        Assert.True(_store.Paused);
        _sync.Dispatch("resume_internet");
        Assert.False(_store.Paused);
    }

    [Fact]
    public void PausePersistsThroughTheStoreAndStatusFile()
    {
        _sync.Dispatch("pause_internet");
        var status = AgentStatus.Read(_statusPath);
        Assert.NotNull(status);
        Assert.True(status!.Paused);
    }

    [Fact]
    public void UnknownCommandLeavesThePauseFlagAlone()
    {
        _sync.Dispatch("pause_internet");
        _sync.Dispatch("definitely_not_a_command");
        Assert.True(_store.Paused);
        _sync.Dispatch(null);
        Assert.True(_store.Paused);
    }

    [Fact]
    public void BonusTimeAddsMinutesToTheStoreCounter()
    {
        Assert.Equal(0, _store.BonusMinutesToday());
        _sync.Dispatch("bonus_time", MinutesPayload(15));
        Assert.Equal(15, _store.BonusMinutesToday());
        _sync.Dispatch("bonus_time", MinutesPayload(15));
        Assert.Equal(30, _store.BonusMinutesToday());
    }

    [Fact]
    public void BonusTimeToleratesAStringMinutesPayload()
    {
        _sync.Dispatch("bonus_time", Payload("{\"minutes\":\"20\"}"));
        Assert.Equal(20, _store.BonusMinutesToday());
    }

    [Fact]
    public void BonusTimeWithoutMinutesLeavesTheCounterAlone()
    {
        _sync.Dispatch("bonus_time", MinutesPayload(0));
        _sync.Dispatch("bonus_time", null);
        _sync.Dispatch("bonus_time", Payload("{\"other\":1}"));
        Assert.Equal(0, _store.BonusMinutesToday());
    }

    [Fact]
    public void WindDownSchedulesTheLockThroughTheInjectedDelay()
    {
        var delays = new List<TimeSpan>();
        // Never-completing delay: the real LockOverlay is out of unit-test scope (same NOTE as
        // the Android agent); we only assert that the scheduled delay carries the right span.
        _sync.Delay = (ts, ct) => { delays.Add(ts); return Task.Delay(Timeout.InfiniteTimeSpan, ct); };
        _sync.Dispatch("wind_down", MinutesPayload(10));
        Assert.Equal([TimeSpan.FromMinutes(10)], delays);
    }

    [Fact]
    public void SecondWindDownCancelsTheFirst()
    {
        var tokens = new List<CancellationToken>();
        _sync.Delay = (_, ct) => { tokens.Add(ct); return Task.Delay(Timeout.InfiniteTimeSpan, ct); };
        _sync.Dispatch("wind_down", MinutesPayload(5));
        _sync.Dispatch("wind_down", MinutesPayload(15));
        Assert.Equal(2, tokens.Count);
        Assert.True(tokens[0].IsCancellationRequested);
        Assert.False(tokens[1].IsCancellationRequested);
    }

    [Fact]
    public void UnlockCancelsAPendingWindDown()
    {
        var tokens = new List<CancellationToken>();
        _sync.Delay = (_, ct) => { tokens.Add(ct); return Task.Delay(Timeout.InfiniteTimeSpan, ct); };
        _sync.Dispatch("wind_down", MinutesPayload(5));
        _sync.Dispatch("unlock");
        var token = Assert.Single(tokens);
        Assert.True(token.IsCancellationRequested);
    }

    [Fact]
    public void WindDownWithoutMinutesSchedulesNothing()
    {
        var delayCalls = 0;
        _sync.Delay = (_, _) => { delayCalls++; return Task.CompletedTask; };
        _sync.Dispatch("wind_down", null);
        _sync.Dispatch("wind_down", MinutesPayload(0));
        Assert.Equal(0, delayCalls);
    }

    private static JsonElement? MinutesPayload(int minutes)
    {
        using var doc = JsonDocument.Parse($$"""{"minutes":{{minutes}}}""");
        return doc.RootElement.Clone();
    }

    private static JsonElement? Payload(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    public void Dispose()
    {
        _store.Dispose();
        try
        {
            Directory.Delete(Path.GetDirectoryName(_dbPath)!, recursive: true);
        }
        catch (Exception)
        {
            // temp cleanup is best-effort
        }
    }
}
