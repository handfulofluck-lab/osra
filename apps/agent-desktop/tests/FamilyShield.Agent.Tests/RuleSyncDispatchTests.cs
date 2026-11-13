using System.Text.Json;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class RuleSyncDispatchTests : IDisposable
{
    private readonly string _dbPath;
    private readonly string _statusPath;
    private readonly LocalRuleStore _store;
    private readonly AgentConfig _config = new() { ParentPin = "4821" };
    private readonly RuleSyncService _sync;
    private readonly TrayUserActions _tray;
    private readonly FakeSink _sink = new();

    public RuleSyncDispatchTests()
    {
        var dir = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"));
        _dbPath = Path.Combine(dir, "agent.db");
        _statusPath = Path.Combine(dir, "status.json");
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, _dbPath, _statusPath);
        var api = new ApiClient(new HttpClient(), new AgentConfig());
        _sync = new RuleSyncService(NullLogger<RuleSyncService>.Instance, _store, api, _config, _sink);
        _tray = new TrayUserActions(_config, _store, NullLogger<TrayUserActions>.Instance);
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
    public void InteractiveCommandsCarryNoPinOrIdentitySecret()
    {
        _sync.Dispatch("lock");
        _sync.Dispatch("pause");
        _sync.Dispatch("resume");
        _sync.Dispatch("ring");
        _sync.Dispatch("wind_down", MinutesPayload(5));

        Assert.Equal(
            [TrayMessageKind.@lock, TrayMessageKind.pause, TrayMessageKind.resume, TrayMessageKind.ring, TrayMessageKind.wind_down],
            _sink.Messages.Select(m => m.Kind).ToArray());
        var json = JsonSerializer.Serialize(_sink.Messages);
        Assert.DoesNotContain("parentPin", json);
        Assert.DoesNotContain("4821", json);
        Assert.DoesNotContain("deviceJwt", json);
        Assert.DoesNotContain("hmacSecret", json);
        Assert.Equal(5, _sink.Messages[^1].Payload!.Value.GetProperty("minutes").GetInt32());
    }

    [Fact]
    public async Task WindDownSchedulesTheLockThroughTheInjectedDelay()
    {
        var delays = new List<TimeSpan>();
        _tray.Delay = (ts, ct) => { delays.Add(ts); return Task.Delay(Timeout.InfiniteTimeSpan, ct); };
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down, MinutesPayload(10)));
        Assert.Equal([TimeSpan.FromMinutes(10)], delays);
    }

    [Fact]
    public async Task SecondWindDownCancelsTheFirst()
    {
        var tokens = new List<CancellationToken>();
        _tray.Delay = (_, ct) => { tokens.Add(ct); return Task.Delay(Timeout.InfiniteTimeSpan, ct); };
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down, MinutesPayload(5)));
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down, MinutesPayload(15)));
        Assert.Equal(2, tokens.Count);
        Assert.True(tokens[0].IsCancellationRequested);
        Assert.False(tokens[1].IsCancellationRequested);
    }

    [Fact]
    public async Task UnlockCancelsAPendingWindDown()
    {
        var tokens = new List<CancellationToken>();
        _tray.Delay = (_, ct) => { tokens.Add(ct); return Task.Delay(Timeout.InfiniteTimeSpan, ct); };
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down, MinutesPayload(5)));
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.unlock));
        var token = Assert.Single(tokens);
        Assert.True(token.IsCancellationRequested);
    }

    [Fact]
    public async Task WindDownWithoutMinutesSchedulesNothing()
    {
        var delayCalls = 0;
        _tray.Delay = (_, _) => { delayCalls++; return Task.CompletedTask; };
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down));
        await _tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down, MinutesPayload(0)));
        Assert.Equal(0, delayCalls);
    }

    [Fact]
    public async Task LockRefusesToArmWithoutAParentPin()
    {
        var shown = new List<string>();
        var tray = NewTrayWithPin(null);
        tray.ShowOverlay = (pin, _, _) => { shown.Add(pin); return true; };
        await tray.HandleAsync(new TrayMessage(TrayMessageKind.@lock));
        Assert.Empty(shown);
        Assert.Equal("lock", tray.LastArmRefusal);
    }

    [Fact]
    public async Task LockUsesExactlyTheConfiguredParentPin()
    {
        var shown = new List<string>();
        var tray = NewTrayWithPin("7391");
        tray.ShowOverlay = (pin, _, _) => { shown.Add(pin); return true; };
        await tray.HandleAsync(new TrayMessage(TrayMessageKind.@lock));
        Assert.Equal("7391", Assert.Single(shown));
        Assert.Null(tray.LastArmRefusal);
    }

    [Fact]
    public async Task LegacyDefaultPinDoesNotArmTheLock()
    {
        var shown = new List<string>();
        var tray = NewTrayWithPin(ParentPinPolicy.LegacyDefault);
        tray.ShowOverlay = (pin, _, _) => { shown.Add(pin); return true; };
        await tray.HandleAsync(new TrayMessage(TrayMessageKind.@lock));
        Assert.Empty(shown);
        Assert.Equal("lock", tray.LastArmRefusal);
    }

    [Fact]
    public async Task PauseRefusesToArmWithoutAParentPin()
    {
        var shown = new List<string>();
        var tray = NewTrayWithPin(null);
        tray.ShowOverlay = (pin, _, _) => { shown.Add(pin); return true; };
        await tray.HandleAsync(new TrayMessage(TrayMessageKind.pause));
        Assert.Empty(shown);
        Assert.Equal("pause", tray.LastArmRefusal);
    }

    [Fact]
    public async Task WindDownIsNotScheduledWithoutAParentPin()
    {
        var delayCalls = 0;
        var tray = NewTrayWithPin(null);
        tray.Delay = (_, _) => { delayCalls++; return Task.CompletedTask; };
        await tray.HandleAsync(new TrayMessage(TrayMessageKind.wind_down, MinutesPayload(5)));
        Assert.Equal(0, delayCalls);
        Assert.Equal("wind_down", tray.LastArmRefusal);
    }

    private TrayUserActions NewTrayWithPin(string? parentPin) =>
        new(new AgentConfig { ParentPin = parentPin }, _store, NullLogger<TrayUserActions>.Instance);

    private static JsonElement? MinutesPayload(int minutes) => Payload($"{{\"minutes\":{minutes}}}");

    private static JsonElement? Payload(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    private sealed class FakeSink : ITrayCommandSink
    {
        public List<TrayMessage> Messages { get; } = [];
        public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
        {
            Messages.Add(message);
            return Task.CompletedTask;
        }
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(Path.GetDirectoryName(_dbPath)!, recursive: true); } catch (Exception) { }
    }
}
