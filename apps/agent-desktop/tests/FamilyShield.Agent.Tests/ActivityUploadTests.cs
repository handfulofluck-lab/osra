using System.Net;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for the Feature #4 persisted activity feed: the ActivityEvent wire shapes,
/// the uploader's "mark rows only after BOTH posts succeed" rule and the Feature #29
/// foreground-app label.
/// </summary>
public sealed class ActivityUploadTests : IDisposable
{
    private readonly LocalRuleStore _store;
    private readonly string _dbPath;

    public ActivityUploadTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N") + ".db");
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, _dbPath);
        _store.Initialize();
    }

    public void Dispose() => _store.Dispose();

    [Fact]
    public void MapperBuildsUrlEventsWithDomainAndBlockedFlag()
    {
        var batch = new TelemetryBatchDto();
        batch.Urls.Add(new UrlLogEntryDto { Ts = "2026-09-16T10:00:00.000Z", Host = "ads.example", Blocked = false });
        batch.Urls.Add(new UrlLogEntryDto { Ts = "2026-09-16T10:01:00.000Z", Host = "bad.example", Blocked = true });

        var events = ActivityEventMapper.FromBatch(batch);

        Assert.Equal(2, events.Count);
        Assert.All(events, e => Assert.Equal("url", e.Type));
        Assert.Equal("2026-09-16T10:00:00.000Z", events[0].Ts);
        Assert.Equal("ads.example", events[0].Payload["domain"]);
        Assert.Equal(false, events[0].Payload["blocked"]);
        Assert.Equal("bad.example", events[1].Payload["domain"]);
        Assert.Equal(true, events[1].Payload["blocked"]);
    }

    [Fact]
    public void MapperBuildsAppUsageEventsWithAppAndMinutes()
    {
        var batch = new TelemetryBatchDto();
        batch.AppUsage.Add(new AppUsageEntryDto { Day = "2026-09-16", Process = "minecraft", Minutes = 12 });

        var events = ActivityEventMapper.FromBatch(batch);

        var single = Assert.Single(events);
        Assert.Equal("app_usage", single.Type);
        Assert.Equal("minecraft", single.Payload["app"]);
        Assert.Equal(12, single.Payload["minutes"]);
    }

    [Fact]
    public async Task PostActivityEventsSerializesTheExactEventShapes()
    {
        var handler = new RecordingHandler();
        var api = new ApiClient(
            new HttpClient(handler) { BaseAddress = new Uri("http://localhost:3000") },
            new AgentConfig());
        var batch = new ActivityEventBatchDto
        {
            Events = ActivityEventMapper.FromBatch(new TelemetryBatchDto
            {
                Urls = { new UrlLogEntryDto { Ts = "2026-09-16T10:00:00.000Z", Host = "bad.example", Blocked = true } },
                AppUsage = { new AppUsageEntryDto { Day = "2026-09-16", Process = "minecraft", Minutes = 12 } },
            }),
        };

        Assert.True(await api.PostActivityEvents("dev-1", batch));

        Assert.EndsWith("/v1/devices/dev-1/activity", handler.LastRequestUri);
        using var doc = System.Text.Json.JsonDocument.Parse(handler.LastBody!);
        var events = doc.RootElement.GetProperty("events");
        Assert.Equal(2, events.GetArrayLength());

        var url = events[0];
        Assert.Equal("url", url.GetProperty("type").GetString());
        Assert.Equal("2026-09-16T10:00:00.000Z", url.GetProperty("ts").GetString());
        Assert.Equal("bad.example", url.GetProperty("payload").GetProperty("domain").GetString());
        Assert.True(url.GetProperty("payload").GetProperty("blocked").GetBoolean());

        var app = events[1];
        Assert.Equal("app_usage", app.GetProperty("type").GetString());
        Assert.False(app.TryGetProperty("ts", out _));
        Assert.Equal("minecraft", app.GetProperty("payload").GetProperty("app").GetString());
        Assert.Equal(12, app.GetProperty("payload").GetProperty("minutes").GetInt32());
    }

    [Fact]
    public async Task UploadOnceMarksRowsOnlyAfterBothPostsSucceed()
    {
        _store.LogUrl("bad.example", "https://bad.example/", "custom", true);
        _store.AddAppMinutes("minecraft", 12);
        var api = new FakeApi { TelemetryOk = true, ActivityOk = true };
        var uploader = new TelemetryUploader(NullLogger<TelemetryUploader>.Instance, _store, api,
            new AgentConfig { DeviceId = "dev-1" });

        await uploader.UploadOnce(CancellationToken.None);

        Assert.Equal(1, api.TelemetryCalls);
        Assert.Equal(1, api.ActivityCalls);
        var sent = Assert.Single(api.Batches);
        Assert.Equal(2, sent.Events.Count);
        Assert.Equal("url", sent.Events[0].Type);
        Assert.Equal("app_usage", sent.Events[1].Type);
        Assert.Empty(_store.GetUnuploadedTelemetry().Urls);
        Assert.Empty(_store.GetUnuploadedTelemetry().AppUsage);
    }

    [Fact]
    public async Task UploadOnceKeepsRowsBufferedWhenActivityPostFails()
    {
        _store.LogUrl("bad.example", "https://bad.example/", "custom", true);
        _store.AddAppMinutes("minecraft", 12);
        var api = new FakeApi { TelemetryOk = true, ActivityOk = false };
        var uploader = new TelemetryUploader(NullLogger<TelemetryUploader>.Instance, _store, api,
            new AgentConfig { DeviceId = "dev-1" });

        await uploader.UploadOnce(CancellationToken.None);

        // Telemetry landed but the derived events did not: rows must stay buffered so the
        // next cycle re-derives and re-posts them (server createMany is idempotent).
        Assert.Equal(1, api.TelemetryCalls);
        Assert.Equal(1, api.ActivityCalls);
        Assert.Single(_store.GetUnuploadedTelemetry().Urls);
        Assert.Single(_store.GetUnuploadedTelemetry().AppUsage);
    }

    [Fact]
    public async Task UploadOnceSkipsActivityPostWhenTelemetryFails()
    {
        _store.LogUrl("bad.example", "https://bad.example/", "custom", true);
        var api = new FakeApi { TelemetryOk = false, ActivityOk = true };
        var uploader = new TelemetryUploader(NullLogger<TelemetryUploader>.Instance, _store, api,
            new AgentConfig { DeviceId = "dev-1" });

        await uploader.UploadOnce(CancellationToken.None);

        Assert.Equal(1, api.TelemetryCalls);
        Assert.Equal(0, api.ActivityCalls);
        Assert.Single(_store.GetUnuploadedTelemetry().Urls);
    }

    [Fact]
    public async Task UploadOnceSkipsActivityPostWhenThereIsNothingToPersist()
    {
        var api = new FakeApi { TelemetryOk = true, ActivityOk = true };
        var uploader = new TelemetryUploader(NullLogger<TelemetryUploader>.Instance, _store, api,
            new AgentConfig { DeviceId = "dev-1" });

        await uploader.UploadOnce(CancellationToken.None);

        // Heartbeat-only cycle: telemetry still POSTs, the empty activity batch is skipped.
        Assert.Equal(1, api.TelemetryCalls);
        Assert.Equal(0, api.ActivityCalls);
    }

    [Theory]
    [InlineData(null, "idle")]
    [InlineData("", "idle")]
    [InlineData("chrome", "chrome")]
    public void ForegroundAppLabelFallsBackToIdle(string? processName, string expected)
    {
        Assert.Equal(expected, ProcessMonitor.ForegroundAppLabel(processName));
    }

    /// <summary>Captures the last request body and URI and answers 200 OK.</summary>
    private sealed class RecordingHandler : HttpMessageHandler
    {
        public string? LastBody { get; private set; }
        public string? LastRequestUri { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastRequestUri = request.RequestUri?.ToString();
            LastBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }

    /// <summary>Fake ApiClient seam recording calls instead of hitting the network.</summary>
    private sealed class FakeApi : ApiClient
    {
        public bool TelemetryOk { get; init; }
        public bool ActivityOk { get; init; }
        public int TelemetryCalls { get; private set; }
        public int ActivityCalls { get; private set; }
        public List<ActivityEventBatchDto> Batches { get; } = [];

        public FakeApi() : base(new HttpClient(), new AgentConfig())
        {
        }

        internal override Task<bool> PostTelemetry(string deviceId, TelemetryBatchDto payload, CancellationToken ct = default)
        {
            TelemetryCalls++;
            return Task.FromResult(TelemetryOk);
        }

        internal override Task<bool> PostActivityEvents(string deviceId, ActivityEventBatchDto batch, CancellationToken ct = default)
        {
            ActivityCalls++;
            Batches.Add(batch);
            return Task.FromResult(ActivityOk);
        }
    }
}
