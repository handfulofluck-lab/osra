using System.Net;
using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Feature #14 SOS hotkey: the alert payload contract and its JSON wire shape, plus the
/// FS_SOS_HOTKEY env gate. Registration itself is Windows-integration and covered by the
/// env gate (same pattern as FS_HTTPS_INSPECT), not by unit tests.
/// </summary>
public sealed class SosHotkeyTests
{
    [Fact]
    public void BuildAlertMatchesTheSosContract()
    {
        var config = new AgentConfig { DeviceId = "dev-1", ChildId = "child-9" };

        var alert = SosHotkey.BuildAlert(config);

        Assert.Equal("sos", alert.Category);
        Assert.Equal("critical", alert.Severity);
        Assert.Equal($"SOS from {Environment.MachineName}", alert.Title);
        Assert.Equal("The SOS hotkey (Shift+F11) was pressed", alert.Body);
        Assert.Equal("dev-1", alert.DeviceId);
        Assert.Equal("child-9", alert.ChildId);
        Assert.Equal("dev-1", alert.Metadata!["deviceId"]);
    }

    [Fact]
    public async Task PostAlertSerializesTheSosShape()
    {
        var handler = new RecordingHandler();
        var api = new ApiClient(
            new HttpClient(handler) { BaseAddress = new Uri("http://localhost:3000") },
            new AgentConfig());

        var ok = await api.PostAlert(SosHotkey.BuildAlert(
            new AgentConfig { DeviceId = "dev-1", ChildId = "child-9" }));

        Assert.True(ok);
        Assert.EndsWith("/v1/alerts/internal", handler.LastRequestUri);
        using var doc = JsonDocument.Parse(handler.LastBody!);
        Assert.Equal("sos", doc.RootElement.GetProperty("category").GetString());
        Assert.Equal("critical", doc.RootElement.GetProperty("severity").GetString());
        Assert.Equal($"SOS from {Environment.MachineName}", doc.RootElement.GetProperty("title").GetString());
        Assert.Equal("The SOS hotkey (Shift+F11) was pressed", doc.RootElement.GetProperty("body").GetString());
        Assert.Equal("dev-1", doc.RootElement.GetProperty("deviceId").GetString());
        Assert.Equal("child-9", doc.RootElement.GetProperty("childId").GetString());
        Assert.Equal("dev-1", doc.RootElement.GetProperty("metadata").GetProperty("deviceId").GetString());
    }

    [Fact]
    public void EnvGateDefaultsToDisabled()
    {
        var previous = Environment.GetEnvironmentVariable(SosHotkey.EnvVar);
        try
        {
            Environment.SetEnvironmentVariable(SosHotkey.EnvVar, null);
            Assert.False(SosHotkey.IsEnabled);
            Environment.SetEnvironmentVariable(SosHotkey.EnvVar, "1");
            Assert.True(SosHotkey.IsEnabled);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SosHotkey.EnvVar, previous);
        }
    }

    /// <summary>Captures the last request body and URI and answers 200 OK.</summary>
    private sealed class RecordingHandler : HttpMessageHandler
    {
        public string? LastBody { get; private set; }
        public string? LastRequestUri { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastRequestUri = request.RequestUri?.ToString();
            LastBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }
}
