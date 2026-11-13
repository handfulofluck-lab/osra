using System.Diagnostics;
using System.Reflection;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class ProcessMonitorProtectionTests
{
    [Fact]
    public void SupervisedTraySurvivesEveryKillRoute()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-protected-process-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var exe = Path.Combine(dir, "k31-probe.exe");
        File.Copy(Path.Combine(Environment.SystemDirectory, "cmd.exe"), exe);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, Path.Combine(dir, "agent.db"), Path.Combine(dir, "status.json"));
        using var child = Process.Start(new ProcessStartInfo(exe, "/k")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        })!;
        try
        {
            var otherNames = Process.GetProcesses().Where(p => p.Id != child.Id).Select(p => p.ProcessName).ToList();
            store.Sync(new RuleSetDto
            {
                AlwaysAllowedApps = otherNames,
                AppRules = [new AppRuleDto { PackageId = child.ProcessName, Action = "block", AppName = "probe" }],
                WebFilter = new WebFilterRuleDto { BlockedCategories = ["probe-category"] },
                Routines = [new RoutineDto { Name = "coverage", StartTime = "00:00", EndTime = "23:59", AllowedApps = otherNames }],
            });
            store.SyncBlocklists(new BlocklistPackDto
            {
                Categories = [new BlocklistCategoryDto { Category = "probe-category", AppsWindows = [child.ProcessName], Domains = [] }],
            });
            store.SetPaused(true);
            var monitor = new ProcessMonitor(NullLogger<ProcessMonitor>.Instance, store,
                new ApiClient(new HttpClient(), new AgentConfig()), new AgentConfig(), process => process.Id == child.Id);

            Invoke(monitor, "EnforcePauseAllowlist", store.Current!);
            Invoke(monitor, "EnforceBlocklistApps", store.Current!, null);
            Invoke(monitor, "KillAll", new[] { child }, child.ProcessName);
            Invoke(monitor, "KillByName", child.ProcessName);
            Invoke(monitor, "Tick");

            Assert.False(child.HasExited);
        }
        finally
        {
            if (!child.HasExited) child.Kill(entireProcessTree: true);
            store.Dispose();
            try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
        }
    }

    private static void Invoke(ProcessMonitor monitor, string name, params object?[] arguments)
    {
        var method = typeof(ProcessMonitor).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new MissingMethodException(name);
        method.Invoke(monitor, arguments);
    }
}
