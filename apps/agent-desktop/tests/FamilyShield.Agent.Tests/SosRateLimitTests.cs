using System.Net;
using System.Reflection;
using System.Text;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class SosRateLimitTests
{
    [Fact]
    public async Task AtMostOneSosPerDevicePerMinuteIsPosted()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-sos-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        var now = new DateTime(2026, 11, 14, 12, 0, 0, DateTimeKind.Utc);
        try
        {
            var alerts = new RecordingAlertHandler();
            var config = new AgentConfig { DeviceId = "device-test", ChildId = "child-test", HmacSecret = "unit-test-secret" };
            using var worker = new TrayServerWorker(
                new FakeSessions([new InteractiveSession(7, "user", true)]), new FakeServerFactory(),
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(alerts) { BaseAddress = new Uri("https://unit.test") }, config), config,
                new TrayServerEvents(), new FakeProcessRegistry(), new DesktopRestrictionState(),
                new FakeSessionFallback(), () => now);
            var handle = typeof(TrayServerWorker).GetMethod("HandleMessage", BindingFlags.Instance | BindingFlags.NonPublic)!;

            await (Task)handle.Invoke(worker, [7, new TrayMessage(TrayMessageKind.sos), CancellationToken.None])!;
            now = now.AddSeconds(59);
            await (Task)handle.Invoke(worker, [7, new TrayMessage(TrayMessageKind.sos), CancellationToken.None])!;
            now = now.AddSeconds(1);
            await (Task)handle.Invoke(worker, [7, new TrayMessage(TrayMessageKind.sos), CancellationToken.None])!;

            Assert.Equal(2, alerts.Count);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeProcessRegistry : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => 42;
    }

    private sealed class FakeServerFactory : ITrayServerFactory
    {
        public ITrayServer Create(int sessionId, string userSid, int expectedPid) => throw new NotSupportedException();
    }

    private sealed class FakeSessionFallback : IDesktopSessionFallback
    {
        public Task LockWorkstation(int sessionId) => Task.CompletedTask;
    }

    private sealed class RecordingAlertHandler : HttpMessageHandler
    {
        public int Count { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Count++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Created)
            {
                Content = new StringContent("{}", Encoding.UTF8, "application/json"),
            });
        }
    }
}
