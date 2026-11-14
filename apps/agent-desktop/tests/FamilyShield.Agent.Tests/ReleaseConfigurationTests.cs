using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

[Collection("Environment variables")]
public sealed class ReleaseConfigurationTests : IDisposable
{
    private static readonly string[] EnvKeys =
        ["API_BASE", "DEVICE_JWT", "DEVICE_ID", "CHILD_ID", "INTERNAL_HMAC_SECRET", ParentPinPolicy.EnvVar, "FS_SET_SYSTEM_PROXY"];

    private readonly string _dir;
    private readonly Dictionary<string, string?> _savedEnv = new();

    public ReleaseConfigurationTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "osra-release-config-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        foreach (var key in EnvKeys)
        {
            _savedEnv[key] = Environment.GetEnvironmentVariable(key);
            Environment.SetEnvironmentVariable(key, null);
        }
    }

    public void Dispose()
    {
        foreach (var (key, value) in _savedEnv) Environment.SetEnvironmentVariable(key, value);
        try { Directory.Delete(_dir, recursive: true); } catch (Exception) { }
    }

    private static AgentConfig StoredConfig() => new()
    {
        ApiBase = "https://stored.invalid",
        DeviceJwt = "file-jwt",
        DeviceId = "file-device",
        ChildId = "file-child",
        HmacSecret = "file-hmac",
        SetSystemProxy = false,
    };

    [Fact]
    public void ReleaseIgnoresEnvironmentAndDoesNotTrustFileConfiguration()
    {
        StoredConfig().Save(_dir);
        Environment.SetEnvironmentVariable("API_BASE", "https://environment.invalid");
        Environment.SetEnvironmentVariable("DEVICE_JWT", "environment-jwt");
        Environment.SetEnvironmentVariable("DEVICE_ID", "environment-device");
        Environment.SetEnvironmentVariable("CHILD_ID", "environment-child");
        Environment.SetEnvironmentVariable("INTERNAL_HMAC_SECRET", "environment-hmac");
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, "4821");
        Environment.SetEnvironmentVariable("FS_SET_SYSTEM_PROXY", "0");

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: false);

        Assert.NotNull(loaded);
        Assert.Equal(AgentConfig.ProductionApiBase, loaded.ApiBase);
        Assert.Equal("file-jwt", loaded.DeviceJwt);
        Assert.Equal("file-device", loaded.DeviceId);
        Assert.Equal("file-child", loaded.ChildId);
        Assert.Equal("file-hmac", loaded.HmacSecret);
        Assert.Null(loaded.ParentPin);
        Assert.True(loaded.SetSystemProxy);
        Assert.False(loaded.AllowEnvironmentOverrides);
    }

    [Fact]
    public void DebugExplicitlyAllowsEnvironmentOverrides()
    {
        StoredConfig().Save(_dir);
        Environment.SetEnvironmentVariable("API_BASE", "https://debug.invalid");
        Environment.SetEnvironmentVariable("DEVICE_JWT", "debug-jwt");
        Environment.SetEnvironmentVariable("DEVICE_ID", "debug-device");
        Environment.SetEnvironmentVariable("CHILD_ID", "debug-child");
        Environment.SetEnvironmentVariable("INTERNAL_HMAC_SECRET", "debug-hmac");
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, "4821");
        Environment.SetEnvironmentVariable("FS_SET_SYSTEM_PROXY", "0");

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);

        Assert.NotNull(loaded);
        Assert.Equal("https://debug.invalid", loaded.ApiBase);
        Assert.Equal("debug-jwt", loaded.DeviceJwt);
        Assert.Equal("debug-device", loaded.DeviceId);
        Assert.Equal("debug-child", loaded.ChildId);
        Assert.Equal("debug-hmac", loaded.HmacSecret);
        Assert.Equal("4821", loaded.ParentPin);
        Assert.False(loaded.SetSystemProxy);
        Assert.True(loaded.AllowEnvironmentOverrides);
    }

    [Fact]
    public void ServiceSnapshotCopiesIdentityOnceWithoutPinOrFileConfiguration()
    {
        var stored = StoredConfig();
        stored.ParentPin = "4821";
        stored.Save(_dir);
        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: false)!;

        var snapshot = loaded.ForService();
        loaded.DeviceJwt = "changed-jwt";
        loaded.DeviceId = "changed-device";
        loaded.ChildId = "changed-child";
        loaded.HmacSecret = "changed-hmac";
        loaded.ApiBase = "https://changed.invalid";
        loaded.SetSystemProxy = false;

        Assert.Equal("file-jwt", snapshot.DeviceJwt);
        Assert.Equal("file-device", snapshot.DeviceId);
        Assert.Equal("file-child", snapshot.ChildId);
        Assert.Equal("file-hmac", snapshot.HmacSecret);
        Assert.Equal(AgentConfig.ProductionApiBase, snapshot.ApiBase);
        Assert.Null(snapshot.ParentPin);
        Assert.True(snapshot.SetSystemProxy);
        Assert.False(snapshot.AllowEnvironmentOverrides);
    }
}
