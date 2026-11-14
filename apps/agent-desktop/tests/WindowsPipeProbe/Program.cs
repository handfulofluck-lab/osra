using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

if (args.Length > 0 && args[0] == "client") return await RunClient();
return await RunService(args);

static async Task<int> RunClient()
{
    var sessionId = Process.GetCurrentProcess().SessionId;
    for (var attempt = 0; attempt < 40; attempt++)
    {
        try
        {
            await using var client = new TrayPipeClient();
            await using var connection = await client.ConnectAsync(sessionId, CancellationToken.None);
            var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToTray);
            if (message.Kind != TrayMessageKind.@lock) return 4;
            Console.WriteLine("OSRA_PIPE_PROBE_PASS");
            return 0;
        }
        catch (UnauthorizedAccessException)
        {
            return 3;
        }
        catch (Exception ex) when (ex is IOException or TimeoutException)
        {
            await Task.Delay(250);
        }
    }
    return 2;
}

static async Task<int> RunService(string[] args)
{
    if (args.Length != 5 || args[0] != "server" ||
        !int.TryParse(args[1], out var sessionId) || !int.TryParse(args[3], out var expectedPid))
    {
        return 64;
    }
    var settings = new ProbeSettings(sessionId, args[2], expectedPid, args[4]);
    var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
    {
        Args = args,
        ContentRootPath = AppContext.BaseDirectory,
    });
    builder.Services.AddWindowsService(options => options.ServiceName = "OSRAPipeProbe-K31");
    builder.Services.AddSingleton(settings);
    builder.Services.AddHostedService<ProbeServer>();
    await builder.Build().RunAsync();
    return 0;
}

sealed record ProbeSettings(int SessionId, string UserSid, int ExpectedPid, string ImagePath);

sealed class ProbeServer(ProbeSettings settings) : BackgroundService
{
    private readonly string _resultPath = Path.Combine(AppContext.BaseDirectory, "probe-result.txt");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await using var server = new TrayPipeServer(settings.SessionId, settings.UserSid, settings.ExpectedPid,
                expectedImagePath: settings.ImagePath);
            await using var connection = await server.AcceptAsync(stoppingToken);
            await TrayProtocol.WriteAsync(connection.Stream, new TrayMessage(TrayMessageKind.@lock),
                TrayDirection.ToTray, stoppingToken);
            ProbeStore(settings.SessionId, settings.UserSid);
            await File.WriteAllTextAsync(_resultPath, "OSRA_SERVICE_STORE_PASS", stoppingToken);
            Console.WriteLine("OSRA_SERVICE_STORE_PASS");
        }
        catch (Exception ex)
        {
            await File.WriteAllTextAsync(_resultPath, ex.ToString(), CancellationToken.None);
            throw;
        }
    }

    private static void ProbeStore(int sessionId, string userSid)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "probe-store", "restrictions.json");
        var store = new FileDesktopRestrictionStore(path);
        var initial = store.Load();
        RequireProtectedDirectory(Path.GetDirectoryName(path)!);
        if (initial.Count != 0)
        {
            try
            {
                store.Save([]);
            }
            catch (Exception ex)
            {
                throw new InvalidDataException("The missing-file load failed; the direct save exposed the cause.", ex);
            }
            throw new InvalidDataException("A missing restriction file was not empty, but the directory and direct save passed.");
        }
        store.Save([new SessionRestriction { SessionId = sessionId, Locked = true, ObservedAt = DateTime.UtcNow }]);
        store.Save([new SessionRestriction
        {
            SessionId = sessionId,
            Locked = true,
            ObservedAt = DateTime.UtcNow,
            FallbackAt = DateTime.UtcNow,
        }]);
        var restored = store.Load();
        if (restored.Count != 1 || !restored[0].Locked || restored[0].FallbackAt is null)
            throw new InvalidDataException("The SYSTEM restriction store did not round-trip.");
        RequireProtectedDirectory(Path.GetDirectoryName(path)!);
        RequireProtectedFile(path);
        ProbeDirectoryRejections(userSid);

        var temporaryPath = Path.Combine(AppContext.BaseDirectory, "probe-temp", "restrictions.json");
        var temporaryStore = new FileDesktopRestrictionStore(temporaryPath, (_, _) => { });
        if (temporaryStore.Load().Count != 0) throw new InvalidDataException("The temporary fixture was not empty.");
        File.WriteAllText(temporaryPath, "[]");
        temporaryStore.Save([new SessionRestriction { SessionId = sessionId, Locked = true }]);
        var temporary = temporaryPath + ".tmp";
        RequireProtectedDirectory(Path.GetDirectoryName(temporaryPath)!);
        RequireProtectedFile(temporary);
        temporaryStore.Save([]);
        if (new FileDesktopRestrictionStore(temporary).Load().Count != 0)
            throw new InvalidDataException("A stale temporary file blocked the latest save.");
        RequireProtectedFile(temporary);

        var corruptPath = Path.Combine(AppContext.BaseDirectory, "probe-corrupt", "restrictions.json");
        var corruptStore = new FileDesktopRestrictionStore(corruptPath);
        if (corruptStore.Load().Count != 0) throw new InvalidDataException("The corrupt fixture could not be created.");
        File.WriteAllText(corruptPath, "not-json");
        var now = DateTime.UtcNow;
        var corruptState = new DesktopRestrictionState(corruptStore);
        if (!corruptState.NeedsFallback(sessionId, now) ||
            corruptState.MessagesFor(sessionId, now).Single().Kind != TrayMessageKind.@lock)
            throw new InvalidDataException("Corrupt state did not fail closed immediately.");
        if (File.ReadAllText(corruptPath) != "not-json")
            throw new InvalidDataException("Loading corrupt state destroyed the evidence.");
        if (!corruptState.MarkFallback(sessionId, now))
            throw new InvalidDataException("Corrupt state did not raise its fallback alert.");
        var recovered = corruptStore.Load().Single(saved => saved.SessionId == sessionId);
        if (!recovered.Locked || recovered.FallbackAt is null || recovered.Unreadable)
            throw new InvalidDataException("The recovered restriction was not persisted.");

        var unlockPath = Path.Combine(AppContext.BaseDirectory, "probe-unlock", "restrictions.json");
        var unlockState = new DesktopRestrictionState(new FileDesktopRestrictionStore(unlockPath));
        unlockState.Observe(sessionId, new TrayMessage(TrayMessageKind.@lock), now);
        unlockState.ObserveDevice(new TrayMessage(TrayMessageKind.unlock), now);
        var afterRestart = new DesktopRestrictionState(new FileDesktopRestrictionStore(unlockPath));
        if (afterRestart.MessagesFor(sessionId, now).Count != 0 ||
            afterRestart.NeedsFallback(sessionId, now.AddSeconds(20)))
            throw new InvalidDataException("Unlock left a disconnected session restricted after restart.");
    }

    private static void ProbeDirectoryRejections(string userSid)
    {
        var untrusted = FixtureDirectory("probe-untrusted-owner", userSid);
        RequireUnreadable(new FileDesktopRestrictionStore(Path.Combine(untrusted, "restrictions.json")).Load(),
            "An untrusted directory owner was accepted.");

        var otherWriter = FixtureDirectory("probe-other-writer", "S-1-5-18", userSid);
        RequireUnreadable(new FileDesktopRestrictionStore(Path.Combine(otherWriter, "restrictions.json")).Load(),
            "Another directory writer was accepted.");

        var target = FixtureDirectory("probe-reparse-target", "S-1-5-18");
        var reparse = Path.Combine(AppContext.BaseDirectory, "probe-reparse");
        Directory.CreateSymbolicLink(reparse, target);
        RequireUnreadable(new FileDesktopRestrictionStore(Path.Combine(reparse, "restrictions.json")).Load(),
            "A reparse-point directory was accepted.");

        var rewrite = Path.Combine(AppContext.BaseDirectory, "probe-acl-rewrite");
        Directory.CreateDirectory(rewrite);
        if (new FileDesktopRestrictionStore(Path.Combine(rewrite, "restrictions.json")).Load().Count != 0)
            throw new InvalidDataException("The ACL-rewrite fixture did not start empty.");
        RequireProtectedDirectory(rewrite);
    }

    private static string FixtureDirectory(string name, string ownerSid, string? otherWriterSid = null)
    {
        var path = Path.Combine(AppContext.BaseDirectory, name);
        Directory.CreateDirectory(path);
        var security = new DirectorySecurity();
        security.SetOwner(new SecurityIdentifier(ownerSid));
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier("S-1-5-18"), FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier("S-1-5-32-544"), FileSystemRights.FullControl, AccessControlType.Allow));
        if (otherWriterSid is not null)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(otherWriterSid), FileSystemRights.FullControl, AccessControlType.Allow));
        }
        new DirectoryInfo(path).SetAccessControl(security);
        return path;
    }

    private static void RequireUnreadable(IReadOnlyList<SessionRestriction> loaded, string message)
    {
        if (loaded.Count != 1 || !loaded[0].Locked || !loaded[0].Unreadable)
            throw new InvalidDataException(message);
    }

    private static void RequireProtectedDirectory(string path)
    {
        var directory = new DirectoryInfo(path);
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidDataException("The restriction directory is a reparse point.");
        var security = directory.GetAccessControl();
        var owner = security.GetOwner(typeof(SecurityIdentifier))?.Value;
        if (owner is not ("S-1-5-18" or "S-1-5-32-544"))
            throw new InvalidDataException("The restriction directory owner is not trusted.");
        RequireOnlySystemAndAdministrators(security);
    }

    private static void RequireProtectedFile(string path) =>
        RequireOnlySystemAndAdministrators(new FileInfo(path).GetAccessControl());

    private static void RequireOnlySystemAndAdministrators(FileSystemSecurity security)
    {
        const FileSystemRights writeRights = FileSystemRights.FullControl | FileSystemRights.Modify |
            FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.CreateFiles | FileSystemRights.CreateDirectories;
        if (!security.AreAccessRulesProtected)
            throw new InvalidDataException("Inherited access rules remain enabled.");
        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>().ToArray();
        foreach (var sid in new[] { "S-1-5-18", "S-1-5-32-544" })
        {
            if (!rules.Any(rule => rule.AccessControlType == AccessControlType.Allow &&
                                  rule.IdentityReference.Value == sid &&
                                  rule.FileSystemRights == FileSystemRights.FullControl))
                throw new InvalidDataException("A required full-control rule is missing.");
        }
        if (rules.Any(rule => rule.AccessControlType == AccessControlType.Allow &&
                              rule.IdentityReference.Value is not ("S-1-5-18" or "S-1-5-32-544") &&
                              (rule.FileSystemRights & writeRights) != 0))
            throw new InvalidDataException("Another principal has write access.");
    }
}
