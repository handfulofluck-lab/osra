using System.Net;
using System.Text.Json;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopAlertSeverityTests
{
    [Theory]
    [InlineData(false, "high")]
    [InlineData(true, "critical")]
    public async Task SaveFailureSeverityFollowsWhetherItSurvivedRestart(bool restoredUnreadable, string expected)
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-alert-severity", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var restrictions = new DesktopRestrictionState(new FailingStore(restoredUnreadable));
            var alerts = new RecordingHandler();
            var config = new AgentConfig { ApiBase = "https://unit.test", DeviceId = "device-test", ChildId = "child-test" };
            using var worker = new TrayServerWorker(new FakeSessions(), new FakeFactory(),
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(alerts) { BaseAddress = new Uri(config.ApiBase) }, config), config,
                new TrayServerEvents(), restrictions: restrictions);

            await worker.SendAsync(new TrayMessage(TrayMessageKind.@lock));
            var body = await alerts.Body.Task.WaitAsync(TimeSpan.FromSeconds(1));
            using var alert = JsonDocument.Parse(body);
            Assert.Equal(expected, alert.RootElement.GetProperty("severity").GetString());
            Assert.Equal("OSRA could not save a setting on the computer", alert.RootElement.GetProperty("title").GetString());
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class FailingStore(bool restoredUnreadable) : IRestrictionStore
    {
        public IReadOnlyList<SessionRestriction> Load() => restoredUnreadable
            ? [new SessionRestriction { SessionId = 0, Locked = true, Unreadable = true }]
            : [];
        public void Save(IReadOnlyList<SessionRestriction> restrictions) => throw new IOException("Write failed.");
    }

    private sealed class RecordingHandler : HttpMessageHandler
    {
        public TaskCompletionSource<string> Body { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Body.TrySetResult(await request.Content!.ReadAsStringAsync(cancellationToken));
            return new HttpResponseMessage(HttpStatusCode.Created);
        }
    }

    private sealed class FakeSessions : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => [];
    }

    private sealed class FakeFactory : ITrayServerFactory
    {
        public ITrayServer Create(int sessionId, string userSid, int expectedPid) => throw new NotSupportedException();
    }
}
