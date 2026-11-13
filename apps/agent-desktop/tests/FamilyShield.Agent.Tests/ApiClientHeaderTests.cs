using System.Net;
using System.Text;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

[Collection("Environment variables")]
public sealed class ApiClientHeaderTests : IDisposable
{
    private readonly string? _savedHmac;
    private readonly string _dir;

    public ApiClientHeaderTests()
    {
        _savedHmac = Environment.GetEnvironmentVariable("INTERNAL_HMAC_SECRET");
        Environment.SetEnvironmentVariable("INTERNAL_HMAC_SECRET", null);
        _dir = Path.Combine(Path.GetTempPath(), "osra-api-header-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable("INTERNAL_HMAC_SECRET", _savedHmac);
        try { Directory.Delete(_dir, recursive: true); } catch (Exception) { }
    }

    private static AgentConfig Config() => new()
    {
        ApiBase = "https://unit.test",
        DeviceJwt = "jwt-unit",
        DeviceId = "device-unit",
        ChildId = "child-unit",
    };

    private static ApiClient Client(RecordingHandler handler, AgentConfig config)
    {
        var http = new HttpClient(handler) { BaseAddress = new Uri(config.ApiBase!) };
        return new ApiClient(http, config);
    }

    [Fact]
    public async Task EveryRequestCarriesTheClientHeader()
    {
        var handler = new RecordingHandler();
        var client = Client(handler, Config());

        await client.GetRules("child-unit");
        await client.GetCommands("device-unit");
        await client.PostTelemetry("device-unit", new TelemetryBatchDto());

        Assert.Equal(3, handler.Requests.Count);
        Assert.All(handler.Requests, request => Assert.Equal(DesktopClientIdentity.Header, request.ClientHeader));
    }

    [Fact]
    public async Task ReleaseDoesNotUseTheEnvironmentHmacFallback()
    {
        Environment.SetEnvironmentVariable("INTERNAL_HMAC_SECRET", "environment-test-value");
        var handler = new RecordingHandler();
        var client = Client(handler, Config());

        await client.PostAlert(new AlertDto { DeviceId = "device-unit", ChildId = "child-unit", Title = "test" });

        var request = Assert.Single(handler.Requests);
        Assert.False(request.HasSignature);
        Assert.Equal(DesktopClientIdentity.Header, request.ClientHeader);
    }

    [Fact]
    public async Task DebugCanUseTheLegacyHmacFallback()
    {
        Environment.SetEnvironmentVariable("INTERNAL_HMAC_SECRET", "environment-test-value");
        Config().Save(_dir);
        var config = AgentConfig.Load(_dir, allowEnvironmentOverrides: true)!;
        var handler = new RecordingHandler();
        var client = Client(handler, config);

        await client.PostAlert(new AlertDto { DeviceId = "device-unit", ChildId = "child-unit", Title = "test" });

        var request = Assert.Single(handler.Requests);
        Assert.True(request.HasSignature);
        Assert.Equal(DesktopClientIdentity.Header, request.ClientHeader);
    }

    private sealed class RecordingHandler : HttpMessageHandler
    {
        public List<(string? ClientHeader, bool HasSignature)> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var clientHeader = request.Headers.TryGetValues("X-OSRA-Client", out var values)
                ? string.Join("", values)
                : null;
            Requests.Add((clientHeader, request.Headers.Contains(InternalSigner.SignatureHeader)));
            var body = request.RequestUri!.AbsolutePath.Contains("/commands") ? "[]" : "{}";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }
}
