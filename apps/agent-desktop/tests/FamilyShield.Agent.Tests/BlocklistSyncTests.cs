using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="LocalRuleStore.SyncBlocklists"/> and
/// <see cref="LocalRuleStore.IsBlockedApp"/> (Feature #1: real blocklist pack on Windows).
/// </summary>
public sealed class BlocklistSyncTests : IDisposable
{
    private readonly LocalRuleStore _store;
    private readonly string _dbPath;

    public BlocklistSyncTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N") + ".db");
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, _dbPath);
        _store.Initialize();
        _store.Sync(BaseRules());
    }

    private static RuleSetDto BaseRules() => new()
    {
        WebFilter = new WebFilterRuleDto
        {
            BlockedCategories = new List<string> { "gambling", "social_media" },
            BlockedDomains = new List<string> { "bad.example" },
        },
    };

    private static BlocklistPackDto Pack(params BlocklistCategoryDto[] categories) => new()
    {
        Version = 1,
        UpdatedAt = "2026-09-16T00:00:00Z",
        Categories = categories.ToList(),
    };

    [Fact]
    public void PackDomainsBlockWhenCategoryIsBlocked()
    {
        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto
            {
                Category = "gambling",
                Domains = new List<string> { "casino.example" },
                AppsWindows = new List<string> { "slots.exe" },
            }));

        Assert.True(_store.ShouldBlock("casino.example", "https://casino.example/"));
        Assert.True(_store.ShouldBlock("www.casino.example", "https://www.casino.example/"));
        Assert.True(_store.IsBlockedApp("slots"));
    }

    [Fact]
    public void PackDomainsForUnblockedCategoryDoNotBlock()
    {
        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto
            {
                Category = "dating",
                Domains = new List<string> { "dating.example" },
                AppsWindows = new List<string> { "matchmaker.exe" },
            }));

        // The pack row exists, but only the synced rule set decides which categories block.
        Assert.Equal("dating", _store.LookupCategory("dating.example"));
        Assert.False(_store.ShouldBlock("dating.example", "https://dating.example/"));
        Assert.True(_store.IsBlockedApp("matchmaker"));
    }

    [Fact]
    public void IsBlockedAppIsExactAndCaseInsensitive()
    {
        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto
            {
                Category = "social_media",
                AppsWindows = new List<string> { "TikTok.exe", "discord.exe" },
            }));

        Assert.True(_store.IsBlockedApp("TIKTOK"));
        Assert.True(_store.IsBlockedApp("tiktok.exe"));
        Assert.True(_store.IsBlockedApp("Discord"));
        Assert.False(_store.IsBlockedApp("tiktok2"));   // not an exact match
        Assert.False(_store.IsBlockedApp("discordapp"));
        Assert.False(_store.IsBlockedApp("minecraft")); // not listed at all
        Assert.False(_store.IsBlockedApp(""));
        Assert.Equal("social_media", _store.LookupAppCategory("tiktok.exe"));
    }

    [Fact]
    public void CustomBlockedDomainsSurvivePackResync()
    {
        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto { Category = "gambling", Domains = new List<string> { "casino.example" } }));
        Assert.True(_store.ShouldBlock("bad.example", "https://bad.example/"));

        // A later rule re-sync plus a new pack must not drop the rule-set-owned 'custom' rows.
        _store.Sync(BaseRules());
        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto { Category = "gambling", Domains = new List<string> { "casino2.example" } }));

        Assert.Equal("custom", _store.LookupCategory("bad.example"));
        Assert.True(_store.ShouldBlock("bad.example", "https://bad.example/"));
        Assert.True(_store.ShouldBlock("casino2.example", "https://casino2.example/"));
    }

    [Fact]
    public void PackResyncReplacesPreviousPackRowsAndApps()
    {
        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto
            {
                Category = "gambling",
                Domains = new List<string> { "casino1.example" },
                AppsWindows = new List<string> { "oldgame.exe" },
            }));
        Assert.Equal("gambling", _store.LookupCategory("casino1.example"));
        Assert.True(_store.IsBlockedApp("oldgame"));

        _store.SyncBlocklists(Pack(
            new BlocklistCategoryDto
            {
                Category = "gambling",
                Domains = new List<string> { "casino2.example" },
                AppsWindows = new List<string> { "newgame.exe" },
            }));

        Assert.Null(_store.LookupCategory("casino1.example")); // old pack rows are gone
        Assert.False(_store.IsBlockedApp("oldgame"));
        Assert.Equal("gambling", _store.LookupCategory("casino2.example"));
        Assert.True(_store.IsBlockedApp("newgame"));
        Assert.Equal("gambling", _store.LookupAppCategory("newgame"));
    }

    [Fact]
    public void BuiltinCategoryDomainsRemainFallbackWhenPackNeverSynced()
    {
        // No SyncBlocklists call at all (e.g. every pack fetch failed): the built-in starter
        // domains seeded by Sync must still block the category.
        Assert.True(_store.ShouldBlock("bet365.com", "http://bet365.com/"));
        Assert.True(_store.ShouldBlock("www.draftkings.com", "http://www.draftkings.com/"));
        Assert.False(_store.IsBlockedApp("bet365"));
    }

    [Fact]
    public void UnblockedCategoriesStayInactive()
    {
        // "pornography" is not in the synced blockedCategories list, so its built-in starter
        // domains were never seeded and must not block.
        Assert.False(_store.ShouldBlock("pornhub.com", "http://pornhub.com/"));
    }

    public void Dispose() => _store.Dispose();
}
