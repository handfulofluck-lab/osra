using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayServerWorkerTests
{
    [Fact]
    public async Task CompletedSessionIsReplacedOnNextSynchronize()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-tray-worker-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var factory = new FakeServerFactory();
            using var worker = new TrayServerWorker(
                new FakeSessions([new InteractiveSession(7, "user", true)]), factory,
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(), new AgentConfig()), new AgentConfig(), new TrayServerEvents(), new FakeProcessRegistry(42));

            worker.Synchronize();
            var first = Assert.Single(factory.Servers);
            for (var attempt = 0; attempt < 100 && !first.Disposed; attempt++)
                await Task.Delay(10);
            Assert.True(first.Disposed, "The fake pipe must reach EOF before the next synchronization pass.");

            worker.Synchronize();

            Assert.Equal(2, factory.Servers.Count);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }
    }

    [Fact]
    public async Task PendingCommandsSurviveAFailedConnection()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-tray-worker-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var factory = new FakeServerFactory();
            using var worker = new TrayServerWorker(
                new FakeSessions([new InteractiveSession(7, "user", true)]), factory,
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(), new AgentConfig()), new AgentConfig(), new TrayServerEvents(), new FakeProcessRegistry(42));
            worker.Synchronize();
            var first = Assert.Single(factory.Servers);
            await worker.SendAsync(new TrayMessage(TrayMessageKind.@lock));
            for (var attempt = 0; attempt < 100 && !first.Disposed; attempt++)
                await Task.Delay(10);
            Assert.True(first.Disposed);

            worker.Synchronize();

            Assert.Equal(2, factory.Servers.Count);
            var second = factory.Servers[1];
            for (var attempt = 0; attempt < 100 && second.Stream is null; attempt++)
                await Task.Delay(10);
            Assert.NotNull(second.Stream);
            var message = await TrayProtocol.ReadAsync(new MemoryStream(second.Stream.ToArray()), TrayDirection.ToTray);
            Assert.Equal(TrayMessageKind.@lock, message.Kind);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeProcessRegistry(int pid) : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => pid;
    }

    private sealed class FakeServerFactory : ITrayServerFactory
    {
        public List<FakeServer> Servers { get; } = [];
        public List<int> ExpectedPids { get; } = [];

        public ITrayServer Create(int sessionId, string userSid, int expectedPid)
        {
            ExpectedPids.Add(expectedPid);
            var server = new FakeServer(sessionId, userSid, failConnection: Servers.Count == 0);
            Servers.Add(server);
            return server;
        }
    }

    private sealed class FakeServer(int sessionId, string userSid, bool failConnection = false) : ITrayServer
    {
        public bool Disposed { get; private set; }
        public MemoryStream? Stream { get; private set; }

        public async Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default)
        {
            if (failConnection)
            {
                await Task.Yield();
                throw new IOException("The first connection failed.");
            }
            Stream = new MemoryStream();
            return new TrayPipeConnection(Stream, sessionId, userSid);
        }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }
}
