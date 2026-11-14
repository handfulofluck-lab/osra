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
                new ApiClient(new HttpClient(), new AgentConfig()), new AgentConfig(), new TrayServerEvents());

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

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeServerFactory : ITrayServerFactory
    {
        public List<FakeServer> Servers { get; } = [];

        public ITrayServer Create(int sessionId, string userSid)
        {
            var server = new FakeServer(sessionId, userSid);
            Servers.Add(server);
            return server;
        }
    }

    private sealed class FakeServer(int sessionId, string userSid) : ITrayServer
    {
        public bool Disposed { get; private set; }

        public Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(new TrayPipeConnection(new MemoryStream(), sessionId, userSid));

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }
}
