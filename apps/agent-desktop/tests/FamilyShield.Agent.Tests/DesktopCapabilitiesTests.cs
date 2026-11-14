using System.Text.Json;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopCapabilitiesTests
{
    [Theory]
    [InlineData(true, "granted")]
    [InlineData(false, "missing")]
    public void ChildAccountAdminReflectsTheInteractiveUser(bool administrator, string expected)
    {
        var report = DesktopCapabilities.Create(new TestAccountIdentity(administrator), Facts());

        Assert.Equal(expected, report.GetProperty("grants").GetProperty("child_account_admin").GetString());
        Assert.Equal("agent-desktop", report.GetProperty("client").GetProperty("app").GetString());
        Assert.Equal("0.1.0", report.GetProperty("client").GetProperty("version").GetString());
        Assert.Equal(1, report.GetProperty("client").GetProperty("build").GetInt32());
        Assert.Equal("dev", report.GetProperty("client").GetProperty("flavour").GetString());
        Assert.Equal("ready", report.GetProperty("features").GetProperty("lock_screen").GetString());
        Assert.Equal("ready", report.GetProperty("features").GetProperty("pause_screen").GetString());
        Assert.Equal("ready", report.GetProperty("features").GetProperty("screen_time").GetString());
        Assert.Equal("ready", report.GetProperty("features").GetProperty("app_blocking").GetString());
        Assert.Equal("degraded", report.GetProperty("features").GetProperty("web_filter").GetString());
        Assert.Equal("degraded", report.GetProperty("features").GetProperty("pause_internet").GetString());
        Assert.Equal(4, report.EnumerateObject().Count());
        Assert.Equal("tray", report.GetProperty("source").GetString());
        Assert.Equal(6, report.GetProperty("features").EnumerateObject().Count());
        Assert.DoesNotContain("not_supported", JsonSerializer.Serialize(report));
        Assert.DoesNotContain("pin", JsonSerializer.Serialize(report).ToLowerInvariant());
        Assert.DoesNotContain("secret", JsonSerializer.Serialize(report).ToLowerInvariant());
        Assert.DoesNotContain("token", JsonSerializer.Serialize(report).ToLowerInvariant());
        Assert.DoesNotContain("apiBase", JsonSerializer.Serialize(report));
    }

    [Fact]
    public async Task TelemetryOmitsCapabilitiesUntilTheTrayReportsThem()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-capability-tests", Guid.NewGuid().ToString("N"));
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, Path.Combine(dir, "agent.db"), Path.Combine(dir, "status.json"));
        var capabilities = new DesktopCapabilitiesStore();
        var api = new FakeApiClient();
        var uploader = new TelemetryUploader(NullLogger<TelemetryUploader>.Instance, store, api,
            new AgentConfig { DeviceId = "device-1" }, capabilities);
        try
        {
            await uploader.UploadOnce(CancellationToken.None);
            Assert.Null(api.Batch!.Capabilities);

            var report = DesktopCapabilities.Create(new TestAccountIdentity(false), Facts());
            capabilities.Update(report);
            await uploader.UploadOnce(CancellationToken.None);
            Assert.NotNull(api.Batch.Capabilities);
            Assert.Equal("missing", api.Batch.Capabilities.Value.GetProperty("grants").GetProperty("child_account_admin").GetString());
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public void StoreRequiresTrayProvenance()
    {
        var report = DesktopCapabilities.Create(new TestAccountIdentity(false), Facts());
        var withoutSource = JsonSerializer.SerializeToElement(new
        {
            client = report.GetProperty("client"),
            grants = report.GetProperty("grants"),
            features = report.GetProperty("features"),
        });
        var wrongSource = JsonSerializer.SerializeToElement(new
        {
            client = report.GetProperty("client"),
            grants = report.GetProperty("grants"),
            features = report.GetProperty("features"),
            source = "service",
        });
        var store = new DesktopCapabilitiesStore();

        Assert.Throws<InvalidDataException>(() => store.Update(withoutSource));
        Assert.Throws<InvalidDataException>(() => store.Update(wrongSource));
    }

    private static RuntimeFacts Facts() => new(
        HasParentPin: true,
        TrayConnected: true,
        ProcessBlocking: true,
        WebFiltering: true);

    private sealed class FakeApiClient : ApiClient
    {
        public TelemetryBatchDto? Batch { get; private set; }
        public FakeApiClient() : base(new HttpClient(), new AgentConfig()) { }
        internal override Task<bool> PostTelemetry(string deviceId, TelemetryBatchDto payload, CancellationToken ct = default)
        {
            Batch = payload;
            return Task.FromResult(true);
        }
        internal override Task<bool> PostActivityEvents(string deviceId, ActivityEventBatchDto batch, CancellationToken ct = default) =>
            Task.FromResult(true);
    }
}

internal sealed class TestAccountIdentity(bool administrator) : IAccountIdentity
{
    public string UserSid { get; } = "test-user";
    public bool IsAdministrator { get; } = administrator;
}
