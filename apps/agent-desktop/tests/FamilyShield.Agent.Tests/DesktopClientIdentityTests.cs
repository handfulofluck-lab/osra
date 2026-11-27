using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopClientIdentityTests
{
    [Theory]
    [InlineData("0.1.0", 1, "agent-desktop/0.1.0+1 (windows)")]
    [InlineData("1.2.3", 42, "agent-desktop/1.2.3+42 (windows)")]
    public void HeaderUsesTheServerGrammar(string version, int build, string expected)
    {
        Assert.Equal(expected, DesktopClientIdentity.CreateHeader(new Version(version), build));
    }

    [Theory]
    [InlineData("0.1", 1)]
    [InlineData("0.1.0", 0)]
    [InlineData("0.1.0", -1)]
    [InlineData("10000.1.0", 1)]
    [InlineData("0.1.0", 1_000_000_000)]
    public void InvalidVersionOrBuildOmitsTheHeader(string version, int build)
    {
        Assert.Null(DesktopClientIdentity.CreateHeader(new Version(version), build));
    }

    [Fact]
    public void MissingVersionOmitsTheHeader()
    {
        Assert.Null(DesktopClientIdentity.CreateHeader(null, 1));
    }

    [Fact]
    public void DefaultHeaderAndCapabilityClientShareOneIdentity()
    {
        Assert.Equal("agent-desktop/0.1.0+1 (windows)", DesktopClientIdentity.Header);
        var client = DesktopClientIdentity.CapabilityClient();
        Assert.NotNull(client);
        Assert.Equal("agent-desktop", client["app"]);
        Assert.Equal("0.1.0", client["version"]);
        Assert.Equal(1, client["build"]);
        Assert.Equal("dev", client["flavour"]);
        Assert.Equal(4, client.Count);
    }
}
