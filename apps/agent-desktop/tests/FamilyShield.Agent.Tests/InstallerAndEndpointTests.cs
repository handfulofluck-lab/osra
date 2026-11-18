using System.Xml.Linq;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
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
    public void InstallerManifestDefinesPerMachineServiceRecoveryAndLockedAcls()
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

        var runKey = doc.Descendants(wix + "RegistryValue")
            .Single(e => e.Attribute("Key")?.Value == @"Software\Microsoft\Windows\CurrentVersion\Run");
        Assert.Equal("HKLM", runKey.Attribute("Root")?.Value);
        Assert.Equal("OSRA", runKey.Attribute("Name")?.Value);

        var permissions = doc.Descendants(util + "PermissionEx").ToList();
        Assert.Contains(permissions, p => p.Attribute("User")?.Value == "SYSTEM" && p.Attribute("GenericAll")?.Value == "yes");
        Assert.Contains(permissions, p => p.Attribute("User")?.Value == "Administrators" && p.Attribute("GenericAll")?.Value == "yes");
        var usersAcl = permissions.Single(p => p.Attribute("User")?.Value == "Users");
        Assert.Equal("yes", usersAcl.Attribute("GenericRead")?.Value);
        Assert.Equal("yes", usersAcl.Attribute("GenericExecute")?.Value);
        Assert.Null(usersAcl.Attribute("GenericAll"));
        Assert.Null(usersAcl.Attribute("GenericWrite"));
    }

    [Fact]
    public async Task SessionSlotDisposeAndDrainAreIdempotent()
    {
        var server = new NoOpTrayServer();
        var slot = new TrayServerWorker.SessionSlot(
            new InteractiveSession(1, "S-1-5-21-1-2-3-1001", true),
            server,
            (_, _, _) => Task.FromResult<TrayMessage?>(null),
            NullLogger<TrayServerWorker>.Instance);

        slot.Dispose();
        slot.Dispose();
        await slot.StopAndDrainAsync();

        Assert.False(slot.IsCompleted);
    }

    private sealed class NoOpTrayServer : ITrayServer
    {
        public Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken) =>
            Task.FromCanceled<TrayPipeConnection>(cancellationToken);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
