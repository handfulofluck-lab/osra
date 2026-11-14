using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using OSRA.Service;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayEndpointIdentityTests
{
    [Fact]
    public void ClientMustBeTheLaunchedPidAndCoLocatedImage()
    {
        const string image = @"C:\agent\OSRA.exe";
        var verifier = new TrayClientIdentity(new FakeIdentitySource(
            new ClientIdentity(7, "user", 42, image)));

        Assert.Null(Record.Exception(() => verifier.Verify(42, 7, "user", 42, image)));
        Assert.Throws<UnauthorizedAccessException>(() => verifier.Verify(42, 7, "user", 41, image));
        Assert.Throws<UnauthorizedAccessException>(() => verifier.Verify(42, 7, "user", 42, @"C:\agent\other.exe"));
        Assert.Throws<UnauthorizedAccessException>(() => verifier.Verify(42, 7, "other", 42, image));
        Assert.Throws<UnauthorizedAccessException>(() => verifier.Verify(42, 8, "user", 42, image));
    }

    [Fact]
    public async Task ClientRefusesANonSystemServerBeforeHello()
    {
        var session = checked(Process.GetCurrentProcess().SessionId + 10000);
        await using var server = new NamedPipeServerStream(
            TrayPipeName.ForSession(session), PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        var connecting = server.WaitForConnectionAsync();
        var reading = TrayProtocol.ReadAsync(server, TrayDirection.ToService);
        var verifier = new FakeServiceIdentityVerifier(false);
        await using var client = new TrayPipeClient(verifier);

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => client.ConnectAsync(session, CancellationToken.None));
        await connecting;
        await Assert.ThrowsAnyAsync<Exception>(() => reading);
        Assert.Equal(Process.GetCurrentProcess().Id, verifier.ServerPid);
    }

    [Fact]
    public void NetworkIsExplicitlyDenied()
    {
        var rules = TrayPipeSecurity.ForSessionUser("S-1-5-21-1234")
            .GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToArray();

        var network = Assert.Single(rules, rule => rule.IdentityReference.Value == "S-1-5-2");
        Assert.Equal(AccessControlType.Deny, network.AccessControlType);
        Assert.True(network.PipeAccessRights.HasFlag(PipeAccessRights.ReadWrite));
    }

    [Fact]
    public void TokenSidNotAccountNameControlsTheAcl()
    {
        const string tokenSid = "S-1-5-21-1111111111";
        var source = new WtsInteractiveSessionSource(
            () => [new InteractiveSession(7, "name-that-maps-to-another-user", true)],
            _ => tokenSid);

        var session = Assert.Single(source.List());
        var rules = TrayPipeSecurity.ForSessionUser(session.UserSid)
            .GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToArray();

        Assert.Equal(tokenSid, session.UserSid);
        Assert.Contains(rules, rule => rule.IdentityReference.Value == tokenSid && rule.AccessControlType == AccessControlType.Allow);
        Assert.DoesNotContain(rules, rule => rule.IdentityReference.Value == "S-1-5-21-other-user");
    }

    [Fact]
    public void WorkerPassesTheLaunchedPidToThePipeFactory()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-endpoint-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var factory = new FakeServerFactory();
            using var worker = new TrayServerWorker(
                new FakeSessions([new InteractiveSession(7, "user", true)]), factory,
                NullLogger<TrayServerWorker>.Instance, new ForegroundActivityAccumulator(store),
                new ApiClient(new HttpClient(), new AgentConfig()), new AgentConfig(), new TrayServerEvents(),
                new FakeProcessRegistry(42));

            worker.Synchronize();

            Assert.Equal([42], factory.ExpectedPids);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class FakeIdentitySource(ClientIdentity identity) : IClientIdentitySource
    {
        public ClientIdentity Read(int clientPid) => identity;
    }

    private sealed class FakeServiceIdentityVerifier(bool accepted) : IServiceIdentityVerifier
    {
        public int ServerPid { get; private set; }
        public bool Verify(int serverPid)
        {
            ServerPid = serverPid;
            return accepted;
        }
    }

    private sealed class FakeProcessRegistry(int pid) : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => pid;
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeServerFactory : ITrayServerFactory
    {
        public List<int> ExpectedPids { get; } = [];

        public ITrayServer Create(int sessionId, string userSid, int expectedPid)
        {
            ExpectedPids.Add(expectedPid);
            return new FakeServer(sessionId, userSid);
        }
    }

    private sealed class FakeServer(int sessionId, string userSid) : ITrayServer
    {
        public Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(new TrayPipeConnection(new MemoryStream(), sessionId, userSid));
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
