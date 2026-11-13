using FamilyShield.Agent.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OSRA.Service;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TraySupervisorTests
{
    [Fact]
    public void OnlyActiveInteractiveSessionsAreSelectedOnce()
    {
        var sessions = new[]
        {
            new InteractiveSession(0, "system", true),
            new InteractiveSession(1, "disconnected", false),
            new InteractiveSession(2, "first", true),
            new InteractiveSession(2, "duplicate", true),
            new InteractiveSession(3, "second", true),
        };

        var selected = TraySupervisor.DesiredSessions(sessions);

        Assert.Equal([2, 3], selected.Select(s => s.SessionId).ToArray());
    }

    [Fact]
    public void OnlyMissingOrExitedTraysAreRestarted()
    {
        var launcher = new FakeLauncher();
        var supervisor = new TraySupervisor(
            new FakeSessions([new InteractiveSession(1, "first", true), new InteractiveSession(2, "second", true)]),
            launcher);

        supervisor.Synchronize();
        supervisor.Synchronize();
        Assert.Equal(2, launcher.Launches.Count);

        launcher.Processes[0].HasExited = true;
        supervisor.Synchronize();

        Assert.Equal(3, launcher.Launches.Count);
        Assert.Equal(1, launcher.Launches[2].SessionId);
        Assert.DoesNotContain(launcher.Processes, process => process.Disposed && !process.HasExited);
        supervisor.Dispose();
    }

    [Fact]
    public void LaunchUsesOnlyTheFixedQuotedInstalledPath()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-supervisor-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var exe = Path.Combine(dir, "OSRA.exe");
        File.WriteAllText(exe, "test placeholder");
        var native = new FakeNativeLauncher();
        var launcher = new SessionProcess(native, dir);
        try
        {
            launcher.StartInstalledTray(new InteractiveSession(7, "user", true));

            var call = Assert.Single(native.Calls);
            var expected = Path.GetFullPath(exe);
            Assert.Equal(7, call.SessionId);
            Assert.Equal(expected, call.ApplicationPath);
            Assert.Equal($"\"{expected}\"", call.CommandLine);
            Assert.Equal("winsta0\\default", call.Desktop);
            Assert.Equal(Path.GetFullPath(dir), call.WorkingDirectory);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public void MissingInstalledTrayIsRejectedWithoutCallingNativeLaunch()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-supervisor-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var native = new FakeNativeLauncher();
        var launcher = new SessionProcess(native, dir);
        try
        {
            Assert.Throws<FileNotFoundException>(() => launcher.StartInstalledTray(new InteractiveSession(7, "user", true)));
            Assert.Empty(native.Calls);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public void ServiceRegistrationHasNoInteractiveWorkers()
    {
        var services = new ServiceCollection();
        ServiceHostComposition.ConfigureServices(services, new AgentConfig());

        var hosted = services.Select(s => s.ImplementationType).Where(t => t is not null && typeof(IHostedService).IsAssignableFrom(t)).ToArray();
        Assert.Contains(typeof(TraySupervisor), hosted);
        Assert.Contains(typeof(RuleSyncService), hosted);
        Assert.Contains(typeof(ProcessMonitor), hosted);
        Assert.Contains(typeof(TelemetryUploader), hosted);
        Assert.DoesNotContain(typeof(ScreenTimeEnforcer), hosted);
        Assert.DoesNotContain(typeof(SosHotkey), hosted);
        Assert.DoesNotContain(services, service => service.ServiceType == typeof(PairingDialog));
    }

    [Fact]
    public void TrayRegistrationHasNoServiceEnforcementWorkers()
    {
        var services = new ServiceCollection();
        DesktopRuntime.AddTray(services, new AgentConfig());

        var hosted = services.Select(s => s.ImplementationType).Where(t => t is not null && typeof(IHostedService).IsAssignableFrom(t)).ToArray();
        Assert.Contains(typeof(ScreenTimeEnforcer), hosted);
        Assert.Contains(typeof(SosHotkey), hosted);
        Assert.DoesNotContain(typeof(ProcessMonitor), hosted);
        Assert.DoesNotContain(typeof(RuleSyncService), hosted);
        Assert.DoesNotContain(typeof(WebFilterProxy), hosted);
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeLauncher : ITrayLauncher
    {
        public List<InteractiveSession> Launches { get; } = [];
        public List<FakeProcess> Processes { get; } = [];

        public ITrayProcess StartInstalledTray(InteractiveSession session)
        {
            Launches.Add(session);
            var process = new FakeProcess();
            Processes.Add(process);
            return process;
        }
    }

    private sealed class FakeProcess : ITrayProcess
    {
        public bool HasExited { get; set; }
        public bool Disposed { get; private set; }
        public void Dispose() => Disposed = true;
    }

    private sealed class FakeNativeLauncher : INativeProcessLauncher
    {
        public List<(int SessionId, string ApplicationPath, string CommandLine, string Desktop, string WorkingDirectory)> Calls { get; } = [];

        public ITrayProcess Launch(int sessionId, string applicationPath, string commandLine, string desktop, string workingDirectory)
        {
            Calls.Add((sessionId, applicationPath, commandLine, desktop, workingDirectory));
            return new FakeProcess();
        }
    }
}
