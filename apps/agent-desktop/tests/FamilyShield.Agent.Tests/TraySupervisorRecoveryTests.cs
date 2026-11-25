using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using OSRA.Service;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TraySupervisorRecoveryTests
{
    [Fact]
    public void LiveCoLocatedTrayIsAdoptedInsteadOfDuplicated()
    {
        var discovery = new FakeDiscovery(_ => new FakeProcess(77));
        var launcher = new FakeLauncher();
        using var supervisor = new TraySupervisor(
            new FakeSessions([new InteractiveSession(7, "user", true)]), launcher,
            NullLogger<TraySupervisor>.Instance, discovery);

        supervisor.Synchronize();
        supervisor.Synchronize();

        Assert.Empty(launcher.Sessions);
        Assert.Equal(77, supervisor.ProcessIdForSession(7));
    }

    [Fact]
    public void OneSessionFailureDoesNotPreventTheNextTray()
    {
        var discovery = new FakeDiscovery(session => session.SessionId == 1
            ? throw new InvalidOperationException("The session is logging off.")
            : null);
        var launcher = new FakeLauncher();
        using var supervisor = new TraySupervisor(
            new FakeSessions([new InteractiveSession(1, "first", true), new InteractiveSession(2, "second", true)]),
            launcher, NullLogger<TraySupervisor>.Instance, discovery);

        supervisor.Synchronize();

        Assert.Equal([2], launcher.Sessions);
    }

    [Fact]
    public void TokenFailureSkipsOnlyTheSessionThatCannotBeRead()
    {
        var source = new WtsInteractiveSessionSource(
            () => [new InteractiveSession(1, "", true), new InteractiveSession(2, "", true)],
            sessionId => sessionId == 1 ? throw new InvalidOperationException("Logoff race") : "second-sid");

        var session = Assert.Single(source.List());
        Assert.Equal(2, session.SessionId);
        Assert.Equal("second-sid", session.UserSid);
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeDiscovery(Func<InteractiveSession, ITrayProcess?> find) : ITrayProcessDiscovery
    {
        public ITrayProcess? FindInstalledTray(InteractiveSession session) => find(session);
    }

    private sealed class FakeLauncher : ITrayLauncher
    {
        public List<int> Sessions { get; } = [];
        public ITrayProcess StartInstalledTray(InteractiveSession session)
        {
            Sessions.Add(session.SessionId);
            return new FakeProcess(42);
        }
    }

    private sealed class FakeProcess(int processId) : ITrayProcess
    {
        public int ProcessId { get; } = processId;
        public bool HasExited { get; set; }
        public void Dispose() { }
    }
}
