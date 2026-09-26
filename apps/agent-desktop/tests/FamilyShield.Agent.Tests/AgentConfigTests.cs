using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="AgentConfig"/>: Load/Save round-trip, missing/corrupt handling,
/// env overrides, and the skip-unchanged write behavior.
/// </summary>
public sealed class AgentConfigTests : IDisposable
{
    private static readonly string[] EnvKeys = ["API_BASE", "DEVICE_JWT", "DEVICE_ID", "CHILD_ID"];

    private readonly string _dir;
    private readonly Dictionary<string, string?> _savedEnv = new();

    public AgentConfigTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "familyshield-agentconfig-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        foreach (var key in EnvKeys)
        {
            _savedEnv[key] = Environment.GetEnvironmentVariable(key);
            Environment.SetEnvironmentVariable(key, null);
        }
    }

    public void Dispose()
    {
        foreach (var (key, value) in _savedEnv)
            Environment.SetEnvironmentVariable(key, value);
        try { Directory.Delete(_dir, recursive: true); } catch (Exception) { }
    }

    private static AgentConfig Sample() => new()
    {
        ApiBase = "http://localhost:3000",
        DeviceJwt = "jwt-1",
        DeviceId = "device-1",
        ChildId = "child-1",
    };

    [Fact]
    public void SaveThenLoadRoundTrips()
    {
        Assert.True(Sample().Save(_dir));

        var loaded = AgentConfig.Load(_dir);
        Assert.NotNull(loaded);
        Assert.Equal("http://localhost:3000", loaded.ApiBase);
        Assert.Equal("jwt-1", loaded.DeviceJwt);
        Assert.Equal("device-1", loaded.DeviceId);
        Assert.Equal("child-1", loaded.ChildId);
    }

    [Fact]
    public void MissingFileReturnsNull()
    {
        Assert.Null(AgentConfig.Load(_dir));
    }

    [Fact]
    public void CorruptFileReturnsNull()
    {
        File.WriteAllText(Path.Combine(_dir, AgentConfig.FileName), "{ not valid json");
        Assert.Null(AgentConfig.Load(_dir));
    }

    [Fact]
    public void EnvVarsOverrideFileValues()
    {
        Sample().Save(_dir);
        Environment.SetEnvironmentVariable("API_BASE", "http://env-server:4000");
        Environment.SetEnvironmentVariable("DEVICE_ID", "env-device");

        var loaded = AgentConfig.Load(_dir);
        Assert.NotNull(loaded);
        Assert.Equal("http://env-server:4000", loaded.ApiBase);
        Assert.Equal("env-device", loaded.DeviceId);
        // Values with no matching env var come from the file.
        Assert.Equal("jwt-1", loaded.DeviceJwt);
        Assert.Equal("child-1", loaded.ChildId);
    }

    [Fact]
    public void EnvVarsCanProvideIdentityWithoutFile()
    {
        Environment.SetEnvironmentVariable("DEVICE_JWT", "env-jwt");
        Environment.SetEnvironmentVariable("CHILD_ID", "env-child");

        var loaded = AgentConfig.Load(_dir);
        Assert.NotNull(loaded);
        Assert.Equal("env-jwt", loaded.DeviceJwt);
        Assert.Equal("env-child", loaded.ChildId);
    }

    [Fact]
    public void SaveSkipsUnchangedFile()
    {
        var config = Sample();
        Assert.True(config.Save(_dir));
        Assert.False(config.Save(_dir));
    }
}
