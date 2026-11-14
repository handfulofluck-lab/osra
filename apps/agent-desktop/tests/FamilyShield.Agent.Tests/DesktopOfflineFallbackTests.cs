using System.Net;
using System.Text;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopOfflineFallbackTests
{
    [Fact]
    public async Task RestrictedSessionFallsBackOnceAndReplaysLockOnReconnect()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-offline-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        var now = new DateTime(2026, 11, 14, 12, 0, 0, DateTimeKind.Utc);
        try
        {
            var factory = new FakeServerFactory();
            var fallback = new RecordingSessionFallback();
            var alerts = new RecordingAlertHandler();
            var config = new AgentConfig { DeviceId = "device-test", ChildId = "child-test", HmacSecret = "unit-test-secret" };
            using var worker = new TrayServerWorker(
                new FakeSessions([new InteractiveSession(7, "user", true)]), factory,
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(alerts) { BaseAddress = new Uri("https://unit.test") }, config), config,
                new TrayServerEvents(), new FakeProcessRegistry(42), new DesktopRestrictionState(), fallback, () => now);
            worker.Synchronize();
            var first = Assert.Single(factory.Servers);
            await worker.SendAsync(new TrayMessage(TrayMessageKind.@lock));
            await ReadKind(first, TrayMessageKind.@lock);

            await worker.EnforceFallback();
            Assert.Empty(fallback.Sessions);
            Assert.Equal(0, alerts.Count);

            now = now.AddSeconds(20);
            await worker.EnforceFallback();
            Assert.Equal([7], fallback.Sessions);
            Assert.Equal(1, alerts.Count);
            await worker.EnforceFallback();
            Assert.Equal([7], fallback.Sessions);
            Assert.Equal(1, alerts.Count);

            worker.Synchronize();
            var second = factory.Servers[1];
            await ReadKind(second, TrayMessageKind.@lock);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public async Task FailedPipeCreateReportsTamperOnce()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-offline-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var fallback = new RecordingSessionFallback();
            var alerts = new RecordingAlertHandler();
            var config = new AgentConfig { DeviceId = "device-test", ChildId = "child-test", HmacSecret = "unit-test-secret" };
            using var worker = new TrayServerWorker(
                new FakeSessions([new InteractiveSession(7, "user", true)]), new ThrowingServerFactory(),
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(alerts) { BaseAddress = new Uri("https://unit.test") }, config), config,
                new TrayServerEvents(), new FakeProcessRegistry(42), new DesktopRestrictionState(), fallback);

            Assert.Throws<UnauthorizedAccessException>(() => worker.Synchronize());
            await worker.EnforceFallback();
            Assert.Equal(1, alerts.Count);
            Assert.Empty(fallback.Sessions);

            Assert.Throws<UnauthorizedAccessException>(() => worker.Synchronize());
            await worker.EnforceFallback();
            Assert.Equal(1, alerts.Count);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public async Task MessageQueuedAfterConnectionIsWritten()
    {
        var server = new FakeServer(7, "user", new DelayedMemoryStream());
        var slot = new TrayServerWorker.SessionSlot(
            new InteractiveSession(7, "user", true), server,
            (_, _, _) => Task.CompletedTask, NullLogger<TrayServerWorker>.Instance);

        var running = slot.RunAsync();
        slot.Enqueue(new TrayMessage(TrayMessageKind.@lock));
        await running;

        await ReadKind(server, TrayMessageKind.@lock);
    }

    private static async Task ReadKind(FakeServer server, TrayMessageKind expected)
    {
        for (var attempt = 0; attempt < 100 && !server.Disposed; attempt++)
            await Task.Delay(10);
        Assert.NotNull(server.Stream);
        var message = await TrayProtocol.ReadAsync(new MemoryStream(server.Stream.ToArray()), TrayDirection.ToTray);
        Assert.Equal(expected, message.Kind);
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeProcessRegistry(int pid) : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => pid;
    }

    private sealed class RecordingSessionFallback : IDesktopSessionFallback
    {
        public List<int> Sessions { get; } = [];
        public Task LockWorkstation(int sessionId)
        {
            Sessions.Add(sessionId);
            return Task.CompletedTask;
        }
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

    private sealed class FakeServerFactory : ITrayServerFactory
    {
        public List<FakeServer> Servers { get; } = [];
        public ITrayServer Create(int sessionId, string userSid, int expectedPid)
        {
            var server = new FakeServer(sessionId, userSid);
            Servers.Add(server);
            return server;
        }
    }

    private sealed class ThrowingServerFactory : ITrayServerFactory
    {
        public ITrayServer Create(int sessionId, string userSid, int expectedPid) =>
            throw new UnauthorizedAccessException("The pipe name is already occupied.");
    }

    private sealed class DelayedMemoryStream : MemoryStream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await Task.Delay(100, cancellationToken);
            return await base.ReadAsync(buffer, cancellationToken);
        }
    }

    private sealed class FakeServer(int sessionId, string userSid, MemoryStream? stream = null) : ITrayServer
    {
        public MemoryStream? Stream { get; private set; } = stream;
        public bool Disposed { get; private set; }
        public Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default)
        {
            Stream ??= new DelayedMemoryStream();
            return Task.FromResult(new TrayPipeConnection(Stream, sessionId, userSid));
        }
        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }
}
