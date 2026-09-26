using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for the Feature #11 pause flag on <see cref="LocalRuleStore"/> (in-memory gate,
/// agent_state persistence, status.json sidecar).
/// </summary>
public sealed class PauseStateTests : IDisposable
{
    private readonly string _dbPath;
    private readonly string _statusPath;

    public PauseStateTests()
    {
        var dir = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"));
        _dbPath = Path.Combine(dir, "agent.db");
        _statusPath = Path.Combine(dir, "status.json");
    }

    private LocalRuleStore NewStore() =>
        new(NullLogger<LocalRuleStore>.Instance, _dbPath, _statusPath);

    [Fact]
    public void StartsUnpaused()
    {
        using var store = NewStore();
        Assert.False(store.Paused);
    }

    [Fact]
    public void SetPausedSetsAndClearsFlag()
    {
        using var store = NewStore();
        store.SetPaused(true);
        Assert.True(store.Paused);
        store.SetPaused(false);
        Assert.False(store.Paused);
    }

    [Fact]
    public void PausePersistsAcrossReopen()
    {
        using (var store = NewStore())
        {
            store.SetPaused(true);
        }

        using (var reopened = NewStore())
        {
            Assert.True(reopened.Paused);
        }
    }

    [Fact]
    public void ResumePersistsAcrossReopen()
    {
        using (var store = NewStore())
        {
            store.SetPaused(true);
            store.SetPaused(false);
        }

        using (var reopened = NewStore())
        {
            Assert.False(reopened.Paused);
        }
    }

    [Fact]
    public void RuleResyncKeepsPauseState()
    {
        using var store = NewStore();
        store.SetPaused(true);
        // A rule re-sync must not wipe the parent's pause decision.
        store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto { BlockedDomains = new List<string> { "bad.example" } },
        });
        Assert.True(store.Paused);
    }

    [Fact]
    public void PauseGateUsesSyncedAllowedDomains()
    {
        using var store = NewStore();
        store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto { AllowedDomains = new List<string> { "school.edu" } },
        });
        store.SetPaused(true);
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("school.edu", store.Current?.AllowedDomains));
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("youtube.com", store.Current?.AllowedDomains));
    }

    [Fact]
    public void SetPausedWritesStatusFile()
    {
        using var store = NewStore();
        store.SetPaused(true);

        var status = AgentStatus.Read(_statusPath);
        Assert.NotNull(status);
        Assert.True(status!.Paused);
        Assert.False(status.HttpsInspect); // FS_HTTPS_INSPECT not set in unit tests
        Assert.False(string.IsNullOrWhiteSpace(status.UpdatedAt));

        store.SetPaused(false);
        var resumed = AgentStatus.Read(_statusPath);
        Assert.NotNull(resumed);
        Assert.False(resumed!.Paused);
    }

    public void Dispose()
    {
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
