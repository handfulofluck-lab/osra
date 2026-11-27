using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="AgentConfig"/>: Load/Save round-trip, missing/corrupt handling,
/// env overrides, W1b plaintext-to-PBKDF2 migration in Release and Debug, and no plaintext PIN on disk or in logs.
/// </summary>
[Collection("Environment variables")]
public sealed class AgentConfigTests : IDisposable
{
    private static readonly string[] EnvKeys =
        ["API_BASE", "DEVICE_JWT", "DEVICE_ID", "CHILD_ID", ParentPinPolicy.EnvVar];

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
        try
        {
            var configPath = Path.Combine(_dir, AgentConfig.FileName);
            if (File.Exists(configPath)) File.SetAttributes(configPath, FileAttributes.Normal);
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception) { }
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

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);
        Assert.NotNull(loaded);
        Assert.Equal(AgentConfig.ProductionApiBase, loaded.ApiBase);
        Assert.Equal("jwt-1", loaded.DeviceJwt);
        Assert.Equal("device-1", loaded.DeviceId);
        Assert.Equal("child-1", loaded.ChildId);
    }

    [Fact]
    public void MissingFileReturnsNull()
    {
        Assert.Null(AgentConfig.Load(_dir, allowEnvironmentOverrides: true));
    }

    [Fact]
    public void CorruptFileReturnsNull()
    {
        File.WriteAllText(Path.Combine(_dir, AgentConfig.FileName), "{ not valid json");
        Assert.Null(AgentConfig.Load(_dir, allowEnvironmentOverrides: true));
    }

    [Fact]
    public void EnvVarsOverrideFileValues()
    {
        Sample().Save(_dir);
        Environment.SetEnvironmentVariable("API_BASE", "http://env-server:4000");
        Environment.SetEnvironmentVariable("DEVICE_ID", "env-device");

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);
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

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);
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

    [Fact]
    public void SaveHashesPlaintextParentPinBeforeWritingToDisk()
    {
        var config = Sample();
        config.ParentPin = "4821";
        Assert.True(config.Save(_dir));

        var raw = File.ReadAllText(Path.Combine(_dir, AgentConfig.FileName));
        Assert.DoesNotContain("4821", raw, StringComparison.Ordinal);
        Assert.Contains("pbkdf2$120000$", raw, StringComparison.Ordinal);

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: false)!;
        Assert.True(ParentPinPolicy.IsStoredHash(loaded.ParentPin));
        Assert.True(ParentPinPolicy.Matches(loaded.ParentPin, "4821"));
        Assert.False(ParentPinPolicy.Matches(loaded.ParentPin, "4822"));
    }

    [Theory]
    [InlineData(false)] // Release
    [InlineData(true)]  // Debug
    public void ExistingPlaintextPinIsMigratedToPbkdf2HashAndRemovedFromDiskOnFirstRun(bool allowEnvironmentOverrides)
    {
        var configPath = Path.Combine(_dir, AgentConfig.FileName);
        var legacyJson = JsonSerializer.Serialize(new
        {
            apiBase = AgentConfig.ProductionApiBase,
            deviceJwt = "jwt-1",
            deviceId = "device-1",
            childId = "child-1",
            parentPin = "4821",
        });
        File.WriteAllText(configPath, legacyJson);

        var firstLoad = AgentConfig.Load(_dir, allowEnvironmentOverrides);
        Assert.NotNull(firstLoad);
        Assert.True(ParentPinPolicy.IsStoredHash(firstLoad.ParentPin));
        Assert.StartsWith("pbkdf2$120000$", firstLoad.ParentPin, StringComparison.Ordinal);
        Assert.True(ParentPinPolicy.Matches(firstLoad.ParentPin, "4821"));

        var rewritten = File.ReadAllText(configPath);
        Assert.DoesNotContain("4821", rewritten, StringComparison.Ordinal);
        using var doc = JsonDocument.Parse(rewritten);
        Assert.Equal(firstLoad.ParentPin, doc.RootElement.GetProperty("parentPin").GetString());

        // Second run keeps the exact same hash without rewriting.
        var secondLoad = AgentConfig.Load(_dir, allowEnvironmentOverrides);
        Assert.Equal(firstLoad.ParentPin, secondLoad!.ParentPin);
    }

    [Fact]
    public void ExistingLegacyZeroDefaultPinIsRemovedFromDiskOnFirstRun()
    {
        var configPath = Path.Combine(_dir, AgentConfig.FileName);
        File.WriteAllText(configPath, """{"deviceJwt":"jwt-1","deviceId":"d-1","childId":"c-1","parentPin":"0000"}""");

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: false);
        Assert.NotNull(loaded);
        Assert.Null(loaded.ParentPin);
        Assert.DoesNotContain("0000", File.ReadAllText(configPath), StringComparison.Ordinal);
    }

    [Fact]
    public void MigrationFailureLogNeverContainsPlaintextPinOrHash()
    {
        var configPath = Path.Combine(_dir, AgentConfig.FileName);
        File.WriteAllText(configPath, """{"deviceJwt":"jwt-1","deviceId":"d-1","childId":"c-1","parentPin":"7391"}""");
        File.SetAttributes(configPath, FileAttributes.ReadOnly);

        var originalErr = Console.Error;
        using var captured = new StringWriter();
        Console.SetError(captured);
        try
        {
            var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: false);
            Assert.NotNull(loaded);
            Assert.True(ParentPinPolicy.Matches(loaded.ParentPin, "7391"));
        }
        finally
        {
            Console.SetError(originalErr);
            File.SetAttributes(configPath, FileAttributes.Normal);
        }

        var logged = captured.ToString();
        Assert.DoesNotContain("7391", logged, StringComparison.Ordinal);
        Assert.DoesNotContain("pbkdf2$", logged, StringComparison.Ordinal);
    }

    [Fact]
    public void EnvParentPinIsAdoptedOnceAsHashIntoTheConfigFile()
    {
        Sample().Save(_dir);
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, "4821");

        var adopted = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);
        Assert.True(ParentPinPolicy.IsStoredHash(adopted!.ParentPin));
        Assert.True(ParentPinPolicy.Matches(adopted.ParentPin, "4821"));

        // Removing the env var must not disarm the install: the hash is now in the file, never plaintext.
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, null);
        var reloaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true)!;
        Assert.Equal(adopted.ParentPin, reloaded.ParentPin);
        var raw = File.ReadAllText(Path.Combine(_dir, AgentConfig.FileName));
        Assert.DoesNotContain("4821", raw, StringComparison.Ordinal);
        Assert.Contains("pbkdf2$120000$", raw, StringComparison.Ordinal);
    }

    [Fact]
    public void LegacyDefaultEnvParentPinIsNotAdopted()
    {
        Sample().Save(_dir);
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, ParentPinPolicy.LegacyDefault);

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);
        Assert.Null(loaded!.ParentPin);
        Assert.DoesNotContain("0000", File.ReadAllText(Path.Combine(_dir, AgentConfig.FileName)));
    }

    [Fact]
    public void MalformedEnvParentPinIsNotAdopted()
    {
        Sample().Save(_dir);
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, "12ab");

        Assert.Null(AgentConfig.Load(_dir, allowEnvironmentOverrides: true)!.ParentPin);
    }

    [Fact]
    public void StoredParentPinWinsOverTheEnvVar()
    {
        var config = Sample();
        config.ParentPin = ParentPinPolicy.Hash("4821");
        config.Save(_dir);
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, "9381");

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true)!;
        Assert.True(ParentPinPolicy.Matches(loaded.ParentPin, "4821"));
        Assert.False(ParentPinPolicy.Matches(loaded.ParentPin, "9381"));
    }

    [Fact]
    public void EnvOnlyIdentityKeepsTheHashedPinInMemoryWithoutWritingAConfigFile()
    {
        Environment.SetEnvironmentVariable("DEVICE_JWT", "env-jwt");
        Environment.SetEnvironmentVariable("CHILD_ID", "env-child");
        Environment.SetEnvironmentVariable(ParentPinPolicy.EnvVar, "4821");

        var loaded = AgentConfig.Load(_dir, allowEnvironmentOverrides: true);

        Assert.True(ParentPinPolicy.IsStoredHash(loaded!.ParentPin));
        Assert.True(ParentPinPolicy.Matches(loaded.ParentPin, "4821"));
        // The migration must not copy an env-only JWT (or the PIN) onto disk.
        Assert.False(File.Exists(Path.Combine(_dir, AgentConfig.FileName)));
    }
}
