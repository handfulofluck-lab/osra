using System.Security.AccessControl;
using System.Security.Principal;
using System.Xml.Linq;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using OSRA.Service;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class InstallerAndEndpointTests
{
    private static string AgentDesktopRoot =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    [Fact]
    public void DefaultBuildPinsProductionApiBaseWithoutTrailingSlash()
    {
        Assert.Equal("https://api.osratech.com", AgentConfig.ProductionApiBase);
        Assert.StartsWith("https://", AgentConfig.ProductionApiBase, StringComparison.Ordinal);
        Assert.False(AgentConfig.ProductionApiBase.EndsWith('/'));
    }

    [Fact]
    public void ProjectDefinesValidatedCompileTimeOsraApiBaseSwitch()
    {
        var csprojPath = Path.Combine(AgentDesktopRoot, "FamilyShield.Agent.csproj");
        var doc = XDocument.Load(csprojPath);
        var osraApiBase = doc.Descendants("OsraApiBase").SingleOrDefault();
        Assert.NotNull(osraApiBase);
        Assert.Equal("https://api.osratech.com", osraApiBase!.Value);
        Assert.Contains("GenerateBuildEndpoint", doc.ToString(), StringComparison.Ordinal);
        Assert.Contains("OSRA001", doc.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void InstallerManifestUsesSidPropertiesServiceRecoveryAndNoDuplicateRunKey()
    {
        var wxsPath = Path.Combine(AgentDesktopRoot, "installer", "OSRA.wxs");
        Assert.True(File.Exists(wxsPath), $"Missing WiX manifest at {wxsPath}");

        var doc = XDocument.Load(wxsPath);
        XNamespace wix = "http://wixtoolset.org/schemas/v4/wxs";
        XNamespace util = "http://wixtoolset.org/schemas/v4/wxs/util";

        var package = doc.Root!.Element(wix + "Package");
        Assert.NotNull(package);
        Assert.Equal("perMachine", package!.Attribute("Scope")?.Value);
        Assert.False(string.IsNullOrWhiteSpace(package.Attribute("UpgradeCode")?.Value));

        Assert.NotEmpty(doc.Descendants(util + "QueryWindowsWellKnownSIDs"));

        var installRoot = doc.Descendants(wix + "StandardDirectory").Single(e => e.Attribute("Id")?.Value == "ProgramFiles64Folder");
        Assert.Contains(installRoot.Descendants(wix + "Directory"), d => d.Attribute("Id")?.Value == "INSTALLFOLDER");

        var serviceInstall = doc.Descendants(wix + "ServiceInstall").Single();
        Assert.Equal("OSRA Service", serviceInstall.Attribute("Name")?.Value);
        Assert.Equal("LocalSystem", serviceInstall.Attribute("Account")?.Value);
        Assert.Equal("auto", serviceInstall.Attribute("Start")?.Value);

        var serviceRecovery = serviceInstall.Element(util + "ServiceConfig");
        Assert.NotNull(serviceRecovery);
        Assert.Equal("restart", serviceRecovery!.Attribute("FirstFailureActionType")?.Value);
        Assert.Equal("restart", serviceRecovery.Attribute("SecondFailureActionType")?.Value);
        Assert.Equal("restart", serviceRecovery.Attribute("ThirdFailureActionType")?.Value);

        Assert.DoesNotContain(doc.Descendants(wix + "RegistryValue"),
            e => string.Equals(e.Attribute("Key")?.Value, @"Software\Microsoft\Windows\CurrentVersion\Run", StringComparison.OrdinalIgnoreCase));

        var permissions = doc.Descendants(util + "PermissionEx").ToList();
        Assert.Contains(permissions, p => p.Attribute("User")?.Value == "[WIX_ACCOUNT_LOCALSYSTEM]" && p.Attribute("GenericAll")?.Value == "yes");
        Assert.Contains(permissions, p => p.Attribute("User")?.Value == "[WIX_ACCOUNT_ADMINISTRATORS]" && p.Attribute("GenericAll")?.Value == "yes");
        var usersAcl = permissions.Single(p => p.Attribute("User")?.Value == "[WIX_ACCOUNT_USERS]");
        Assert.Equal("yes", usersAcl.Attribute("GenericRead")?.Value);
        Assert.Equal("yes", usersAcl.Attribute("GenericExecute")?.Value);
        Assert.Null(usersAcl.Attribute("GenericAll"));
        Assert.Null(usersAcl.Attribute("GenericWrite"));
    }

    [Fact]
    public async Task SessionSlotStartDisposeAndDrainCompleteCleanly()
    {
        var server = new WaitingTrayServer();
        var slot = new TrayServerWorker.SessionSlot(
            new InteractiveSession(1, "S-1-5-21-1-2-3-1001", true),
            server,
            (_, _, _) => Task.FromResult<TrayMessage?>(null),
            NullLogger<TrayServerWorker>.Instance);

        slot.Start();
        await server.AcceptEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        slot.Dispose();
        slot.Dispose();
        await slot.StopAndDrainAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(slot.IsCompleted);
        Assert.True(server.Disposed);
    }

    [Fact]
    public void TraySupervisorWaitsUntilPairedBeforeLaunchingSessionTray()
    {
        var paired = false;
        var launcher = new CountingTrayLauncher();
        var supervisor = new TraySupervisor(
            new SingleSessionSource(),
            launcher,
            NullLogger<TraySupervisor>.Instance,
            discovery: null,
            isPaired: () => paired);

        supervisor.Synchronize();
        Assert.Equal(0, launcher.LaunchCount);

        paired = true;
        supervisor.Synchronize();
        Assert.Equal(1, launcher.LaunchCount);
        supervisor.Dispose();
    }

    [Fact]
    public async Task RuntimeCoordinatorPollsAndStartsRuntimeOnceConfigAppears()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-coord-poll-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(dir, "agent.db"), Path.Combine(dir, "status.json"));
        AgentConfig? stored = null;
        var host = new StubHost();
        using var coordinator = new RuntimeCoordinator(
            new AgentConfig { ApiBase = AgentConfig.ProductionApiBase },
            store,
            new NoOpSink(),
            new DesktopCapabilitiesStore(),
            load: () => Volatile.Read(ref stored),
            hostFactory: _ => host,
            pollInterval: TimeSpan.FromMilliseconds(20));

        try
        {
            await coordinator.StartAsync(CancellationToken.None);
            Assert.False(coordinator.RuntimeStarted);

            Volatile.Write(ref stored, new AgentConfig
            {
                DeviceJwt = "jwt",
                DeviceId = "dev-1",
                ChildId = "child-1",
                HmacSecret = "hmac",
            });

            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (!coordinator.RuntimeStarted && DateTime.UtcNow < deadline)
                await Task.Delay(20);

            Assert.True(coordinator.RuntimeStarted);
            Assert.Equal(1, host.Starts);
        }
        finally
        {
            await coordinator.StopAsync(CancellationToken.None);
            store.Dispose();
            try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public void PairingChecksDirectoryWritabilityBeforeClaimingCode()
    {
        var missing = Path.Combine(Path.GetTempPath(), "osra-missing-" + Guid.NewGuid().ToString("N"));
        Assert.False(AgentConfig.CanPersist(missing));

        var writable = Path.Combine(Path.GetTempPath(), "osra-writable-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(writable);
        try
        {
            Assert.True(AgentConfig.CanPersist(writable));
            var info = new DirectoryInfo(writable);
            var security = info.GetAccessControl();
            var me = WindowsIdentity.GetCurrent().User!;
            security.AddAccessRule(new FileSystemAccessRule(me, FileSystemRights.CreateFiles | FileSystemRights.WriteData, AccessControlType.Deny));
            info.SetAccessControl(security);

            Assert.False(AgentConfig.CanPersist(writable));
        }
        finally
        {
            if (Directory.Exists(writable))
            {
                var info = new DirectoryInfo(writable);
                var security = info.GetAccessControl();
                var me = WindowsIdentity.GetCurrent().User!;
                security.RemoveAccessRule(new FileSystemAccessRule(me, FileSystemRights.CreateFiles | FileSystemRights.WriteData, AccessControlType.Deny));
                info.SetAccessControl(security);
                try { Directory.Delete(writable, recursive: true); } catch (Exception) { }
            }
        }

        var pairingDialogSource = File.ReadAllText(Path.Combine(AgentDesktopRoot, "Services", "PairingDialog.cs"));
        var canPersistIdx = pairingDialogSource.IndexOf("AgentConfig.CanPersist", StringComparison.Ordinal);
        var claimIdx = pairingDialogSource.IndexOf("PairingService.ClaimAsync", StringComparison.Ordinal);
        Assert.True(canPersistIdx > 0 && claimIdx > canPersistIdx,
            "PairingDialog must verify write permission before claiming a pairing code on the server.");
    }

    private sealed class WaitingTrayServer : ITrayServer
    {
        private readonly TaskCompletionSource<TrayPipeConnection> _tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource AcceptEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Disposed { get; private set; }

        public async Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken)
        {
            AcceptEntered.TrySetResult();
            using var reg = cancellationToken.Register(() => _tcs.TrySetCanceled(cancellationToken));
            return await _tcs.Task;
        }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class SingleSessionSource : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => [new InteractiveSession(1, "S-1-5-21-1-2-3-1001", true)];
    }

    private sealed class CountingTrayLauncher : ITrayLauncher
    {
        public int LaunchCount { get; private set; }
        public ITrayProcess StartInstalledTray(InteractiveSession session)
        {
            LaunchCount++;
            return new StubTrayProcess();
        }
    }

    private sealed class StubTrayProcess : ITrayProcess
    {
        public int ProcessId => 4242;
        public bool HasExited => false;
        public void Dispose() { }
    }

    private sealed class NoOpSink : ITrayCommandSink
    {
        public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }

    private sealed class StubHost : IHost
    {
        public int Starts { get; private set; }
        public IServiceProvider Services => throw new NotSupportedException();
        public Task StartAsync(CancellationToken cancellationToken = default) { Starts++; return Task.CompletedTask; }
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public void Dispose() { }
    }
}
