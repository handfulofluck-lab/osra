using FamilyShield.Agent;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="LocalRuleStore"/>: rule sync, domain blocking,
/// usage-minute accumulation and the telemetry upload cursor.
/// </summary>
public sealed class LocalRuleStoreTests : IDisposable
{
    private readonly LocalRuleStore _store;
    private readonly string _dbPath;

    public LocalRuleStoreTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N") + ".db");
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, _dbPath);
        _store.Initialize();
        _store.Sync(SampleRules());
    }

    private static RuleSetDto SampleRules() => new()
    {
        ScreenTime = new ScreenTimeRuleDto { DailyLimitMinutes = 120, WeekendLimitMinutes = 180, BedtimeStart = "21:00", BedtimeEnd = "07:00" },
        WebFilter = new WebFilterRuleDto
        {
            BlockedCategories = new List<string> { "gambling" },
            AllowedDomains = new List<string> { "school.edu" },
            BlockedDomains = new List<string> { "bad.example" },
            SafeSearchEnforced = true,
        },
        AppRules = new List<AppRuleDto>
        {
            new() { PackageId = "minecraft", AppName = "Minecraft", Action = "time_limit", DailyLimitMinutes = 45 },
        },
    };

    [Fact]
    public void AllowedDomainWinsOverCategory()
    {
        Assert.False(_store.ShouldBlock("school.edu", "https://school.edu/page"));
    }

    [Fact]
    public void BlockedDomainMatchesSubdomains()
    {
        Assert.True(_store.ShouldBlock("bad.example", "https://bad.example/"));
        Assert.True(_store.ShouldBlock("ads.bad.example", "https://ads.bad.example/x"));
        Assert.False(_store.ShouldBlock("notbad.example.org", "https://notbad.example.org/"));
    }

    [Fact]
    public void CategoryBlockListBlocksKnownHost()
    {
        // Simulate a downloaded category blocklist entry.
        Assert.Equal("custom", _store.LookupCategory("bad.example"));
    }

    [Fact]
    public void BuiltinCategoryDomainsBlockWithoutDownloadedList()
    {
        Assert.Equal("gambling", _store.LookupCategory("bet365.com"));
        Assert.True(_store.ShouldBlock("bet365.com", "http://bet365.com/"));
        Assert.True(_store.ShouldBlock("www.draftkings.com", "http://www.draftkings.com/"));
        Assert.False(_store.ShouldBlock("wikipedia.org", "http://wikipedia.org/"));
    }

    [Fact]
    public void MinutesUsedTodayAccumulatesPerProcess()
    {
        Assert.Equal(0, _store.MinutesUsedToday("minecraft"));
        _store.AddAppMinutes("minecraft", 15);
        _store.AddAppMinutes("minecraft", 10);
        _store.AddAppMinutes("browser", 5);
        Assert.Equal(25, _store.MinutesUsedToday("minecraft"));
        Assert.Equal(30, _store.MinutesUsedToday());
    }

    [Fact]
    public void TelemetryBatchUploadsOnceThenClears()
    {
        _store.LogUrl("bad.example", "https://bad.example/", "custom", true);
        _store.AddAppMinutes("minecraft", 12);

        var batch = _store.GetUnuploadedTelemetry();
        Assert.Single(batch.Urls);
        Assert.True(batch.Urls[0].Blocked);
        Assert.Equal(12, batch.AppUsage.Sum(a => a.Minutes));
        Assert.True(batch.UrlLogCursor > 0);

        _store.MarkTelemetryUploaded(batch.UrlLogCursor);
        var after = _store.GetUnuploadedTelemetry();
        Assert.Empty(after.Urls);
        Assert.Empty(after.AppUsage);
    }

    [Fact]
    public void SyncReplacesPreviousRules()
    {
        var updated = SampleRules();
        updated.WebFilter!.BlockedDomains = new List<string> { "worse.example" };
        _store.Sync(updated);
        Assert.False(_store.ShouldBlock("bad.example", "https://bad.example/"));
        Assert.True(_store.ShouldBlock("worse.example", "https://worse.example/"));
    }

    [Fact]
    public void SuffixMatchRequiresALabelBoundary()
    {
        _store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto { BlockedDomains = new List<string> { "example.com" } },
        });
        Assert.True(_store.ShouldBlock("example.com", "http://example.com/"));
        Assert.True(_store.ShouldBlock("www.example.com", "http://www.example.com/"));
        // "badexample.com" merely ends with the letters; it is not a subdomain and must pass.
        Assert.False(_store.ShouldBlock("badexample.com", "http://badexample.com/"));
        Assert.Null(_store.LookupCategory("badexample.com"));
        Assert.Equal("custom", _store.LookupCategory("www.example.com"));
    }

    [Fact]
    public void AllowedSubdomainWinsOverBlockedParentDomain()
    {
        _store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto
            {
                AllowedDomains = new List<string> { "good.example.com" },
                BlockedDomains = new List<string> { "example.com" },
            },
        });
        Assert.False(_store.ShouldBlock("good.example.com", "http://good.example.com/"));
        Assert.False(_store.ShouldBlock("mail.good.example.com", "http://mail.good.example.com/"));
        Assert.True(_store.ShouldBlock("other.example.com", "http://other.example.com/"));
        Assert.True(_store.ShouldBlock("example.com", "http://example.com/"));
    }

    [Fact]
    public void UrlLogCursorKeepsRowsLoggedAfterTheBatchWasRead()
    {
        _store.LogUrl("a.example", "http://a.example/", null, false);
        var batch = _store.GetUnuploadedTelemetry();
        Assert.Single(batch.Urls);

        // A row racing in after the read must not be marked uploaded by this batch's ack.
        _store.LogUrl("b.example", "http://b.example/", null, true);
        _store.MarkTelemetryUploaded(batch.UrlLogCursor);

        var next = _store.GetUnuploadedTelemetry();
        var entry = Assert.Single(next.Urls);
        Assert.Equal("b.example", entry.Host);
        Assert.True(entry.Blocked);
    }

    [Fact]
    public void MarkingAnEmptyBatchIsANoOp()
    {
        var batch = _store.GetUnuploadedTelemetry();
        Assert.Equal(0, batch.UrlLogCursor);
        _store.LogUrl("a.example", "http://a.example/", null, false);
        _store.MarkTelemetryUploaded(batch.UrlLogCursor);
        Assert.Single(_store.GetUnuploadedTelemetry().Urls);
    }

    [Fact]
    public void AppUsageRowsAreReUploadedWithCumulativeMinutes()
    {
        _store.AddAppMinutes("minecraft", 10);
        var first = _store.GetUnuploadedTelemetry();
        Assert.Equal(10, first.AppUsage.Sum(a => a.Minutes));
        _store.MarkTelemetryUploaded(first.UrlLogCursor);
        Assert.Empty(_store.GetUnuploadedTelemetry().AppUsage);

        // Minutes counted after the upload must not be lost: the row re-flags itself and the
        // next batch carries the cumulative total (the server keeps the latest batch wholesale).
        _store.AddAppMinutes("minecraft", 5);
        var second = _store.GetUnuploadedTelemetry();
        var row = Assert.Single(second.AppUsage);
        Assert.Equal("minecraft", row.Process);
        Assert.Equal(15, row.Minutes);
    }

    [Fact]
    public void IdleRowsDoNotCountTowardTotalMinutesUsedToday()
    {
        _store.AddAppMinutes("game", 15);
        _store.AddAppMinutes("idle", 60);
        Assert.Equal(15, _store.MinutesUsedToday());
        Assert.Equal(15, _store.MinutesUsedToday("game"));
        Assert.Equal(60, _store.MinutesUsedToday("idle"));
    }

    public void Dispose() => _store.Dispose();
}
