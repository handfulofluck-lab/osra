using System.Net;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayServerResilienceTests
{
    [Fact]
    public async Task FailedCreateRetainsPendingCommandsAndContinuesOtherSessions()
    {
        using var fixture = new Fixture([new InteractiveSession(1, "first", true), new InteractiveSession(2, "second", true)]);
        fixture.Worker.Synchronize();
        var first = fixture.Factory.Servers.Single(server => server.SessionId == 1);
        await fixture.Worker.SendAsync(new TrayMessage(TrayMessageKind.ring));
        await WaitUntil(() => first.Disposed);

        fixture.Factory.FailCreates.Add(1);
        fixture.Worker.Synchronize();
        Assert.Contains(fixture.Factory.Servers, server => server.SessionId == 2);

        fixture.Factory.FailCreates.Remove(1);
        fixture.Worker.Synchronize();
        var replacement = fixture.Factory.Servers.Last(server => server.SessionId == 1);
        var message = await ReadFrame(replacement);
        Assert.Equal(TrayMessageKind.ring, message.Kind);
    }

    [Fact]
    public async Task FailedSynchronizeStillWaitsBeforeRetrying()
    {
        using var fixture = new Fixture([new InteractiveSession(7, "user", true)]);
        fixture.Factory.FailCreates.Add(7);
        fixture.Sessions.FailAfter = 1;
        var delayed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Delay = (period, cancellationToken) =>
        {
            Assert.Equal(TimeSpan.FromSeconds(5), period);
            delayed.TrySetResult();
            return Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        };

        await fixture.Worker.StartAsync(CancellationToken.None);
        try
        {
            await delayed.Task.WaitAsync(TimeSpan.FromMilliseconds(250));
        }
        finally
        {
            await fixture.Worker.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task FallbackEnumerationFailureDoesNotEscapeTheWorker()
    {
        using var fixture = new Fixture([]);
        fixture.Sessions.Failure = new InvalidOperationException("Session enumeration failed.");

        await fixture.Worker.EnforceFallback();
        await fixture.Worker.SendAsync(new TrayMessage(TrayMessageKind.@lock));
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++) await Task.Delay(10);
        Assert.True(condition());
    }

    private static async Task<TrayMessage> ReadFrame(FakeServer server)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (server.Stream is { } stream)
            {
                var bytes = stream.ToArray();
                if (bytes.Length >= 4 && bytes.Length >= 4 + BitConverter.ToInt32(bytes, 0))
                    return await TrayProtocol.ReadAsync(new MemoryStream(bytes), TrayDirection.ToTray);
            }
            await Task.Delay(10);
        }
        throw new TimeoutException("The retained command was not written.");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly LocalRuleStore _store;
        private readonly string _directory;
        public FakeSessions Sessions { get; }
        public FakeFactory Factory { get; } = new();
        public Func<TimeSpan, CancellationToken, Task>? Delay { get; set; }
        public TrayServerWorker Worker { get; }

        public Fixture(IReadOnlyList<InteractiveSession> sessions)
        {
            Sessions = new FakeSessions(sessions);
            _directory = Path.Combine(Path.GetTempPath(), "osra-server-resilience", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_directory);
            _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
                Path.Combine(_directory, "rules.db"), Path.Combine(_directory, "status.json"));
            var config = new AgentConfig { ApiBase = "https://unit.test" };
            Worker = new TrayServerWorker(Sessions, Factory, NullLogger<TrayServerWorker>.Instance,
                new ForegroundActivityAccumulator(_store),
                new ApiClient(new HttpClient(new SuccessHandler()) { BaseAddress = new Uri(config.ApiBase) }, config),
                config, new TrayServerEvents(), new FakeRegistry(),
                delay: (period, cancellationToken) => Delay?.Invoke(period, cancellationToken) ?? Task.Delay(period, cancellationToken));
        }

        public void Dispose()
        {
            Worker.Dispose();
            _store.Dispose();
            try { Directory.Delete(_directory, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        private int _calls;
        public Exception? Failure { get; set; }
        public int? FailAfter { get; set; }
        public IReadOnlyList<InteractiveSession> List()
        {
            if (Failure is not null) throw Failure;
            if (FailAfter is { } count && _calls++ >= count) throw new InvalidOperationException("Session enumeration failed.");
            return sessions;
        }
    }

    private sealed class FakeRegistry : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => 42;
    }

    private sealed class FakeFactory : ITrayServerFactory
    {
        public List<FakeServer> Servers { get; } = [];
        public HashSet<int> FailCreates { get; } = [];
        public ITrayServer Create(int sessionId, string userSid, int expectedPid)
        {
            if (FailCreates.Contains(sessionId)) throw new UnauthorizedAccessException("Pipe create failed.");
            var server = new FakeServer(sessionId);
            Servers.Add(server);
            return server;
        }
    }

    private sealed class FakeServer(int sessionId) : ITrayServer
    {
        public int SessionId { get; } = sessionId;
        public MemoryStream? Stream { get; private set; }
        public bool Disposed { get; private set; }
        public Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default)
        {
            Stream = new MemoryStream();
            return Task.FromResult(new TrayPipeConnection(Stream, SessionId, "user"));
        }
        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class SuccessHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.Created));
    }
}
