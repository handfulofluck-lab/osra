using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Pins the active (post-#608) user-visible data folder to OSRA for the production consumers, so a
/// regression back to the legacy folder name fails here rather than silently at runtime.
/// </summary>
public sealed class DataFolderTests
{
    private static string LocalAppData =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    [Fact]
    public void DefaultPathIsLocalAppDataOsra()
    {
        Assert.Equal(Path.Combine(LocalAppData, "OSRA"), DataFolder.DefaultPath);
    }

    [Fact]
    public void StatusFileLivesUnderOsra()
    {
        Assert.Equal(Path.Combine(LocalAppData, "OSRA", "status.json"), AgentStatus.DefaultPath);
    }

    [Fact]
    public void RuleDatabaseLivesUnderOsra()
    {
        Assert.Equal(Path.Combine(LocalAppData, "OSRA", "agent.db"), LocalRuleStore.DefaultDbPath);
    }
}
