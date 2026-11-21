using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Security.Principal;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayWorkerLoopbackTests
{
    [Fact]
    public async Task RealWorkersDeliverAfterHelloAndSurviveTwentyQuietSeconds()
    {
        using var gate = TrayPipeTestGate.Acquire();
        var directory = Path.Combine(Path.GetTempPath(), "osra-worker-loopback", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        var session = Process.GetCurrentProcess().SessionId;
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        var pid = Process.GetCurrentProcess().Id;
        var config = new AgentConfig { ApiBase = "https://unit.test" };
        var state = new TrayConnectionState();
        var actions = new TrayUserActions(new AgentConfig(), store, NullLogger<TrayUserActions>.Instance);
        var rung = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        actions.RingAction = () => rung.TrySetResult();
        var fallback = new FakeFallback();
        var serverLog = new ListLogger<TrayServerWorker>();
        var clientLog = new ListLogger<TrayPipeClientWorker>();
        using var server = new TrayServerWorker(new FakeSessions(session, sid), new RealServerFactory(),
            serverLog, new ForegroundActivityAccumulator(store),
            new ApiClient(new HttpClient(new SuccessHandler()) { BaseAddress = new Uri(config.ApiBase) }, config),
            config, new TrayServerEvents(), new FakeRegistry(pid), new DesktopRestrictionState(), fallback);
        using var client = new TrayPipeClientWorker(new TrayPipeClient(new AcceptingVerifier()), actions,
            clientLog, state);
        try
        {
            await server.StartAsync(CancellationToken.None);
            await client.StartAsync(CancellationToken.None);
            await server.SendAsync(new TrayMessage(TrayMessageKind.@lock));
            for (var attempt = 0; attempt < 500 && actions.LastArmRefusal != "lock"; attempt++)
                await Task.Delay(10);
            Assert.True(actions.LastArmRefusal == "lock",
                $"Lock did not arrive. Connected={state.IsConnected}; server={string.Join(" | ", serverLog.Entries)}; client={string.Join(" | ", clientLog.Entries)}");

            await Task.Delay(TimeSpan.FromSeconds(20));
            Assert.True(state.IsConnected);
            Assert.Empty(fallback.Sessions);

            await server.SendAsync(new TrayMessage(TrayMessageKind.ring));
            await rung.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            await client.StopAsync(CancellationToken.None);
            await server.StopAsync(CancellationToken.None);
            client.Dispose();
            server.Dispose();
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class RealServerFactory : ITrayServerFactory
    {
        public ITrayServer Create(int sessionId, string userSid, int expectedPid) =>
            new TrayPipeServer(sessionId, userSid, expectedPid,
                expectedImagePath: Process.GetCurrentProcess().MainModule!.FileName);
    }

    private sealed class FakeSessions(int sessionId, string sid) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => [new InteractiveSession(sessionId, sid, true)];
    }

    private sealed class FakeRegistry(int pid) : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => pid;
    }

    private sealed class FakeFallback : IDesktopSessionFallback
    {
        public List<int> Sessions { get; } = [];
        public Task LockWorkstation(int sessionId)
        {
            Sessions.Add(sessionId);
            return Task.CompletedTask;
        }
    }

    private sealed class AcceptingVerifier : IServiceIdentityVerifier
    {
        public bool Verify(PipeStream stream) => true;
    }

    private sealed class SuccessHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.Created));
    }

    private sealed class ListLogger<T> : ILogger<T>
    {
        public List<string> Entries { get; } = [];
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state,
            Exception? exception, Func<TState, Exception?, string> formatter)
        {
            lock (Entries) Entries.Add($"{logLevel}:{exception?.GetType().Name}:{formatter(state, exception)}");
        }
    }
}
