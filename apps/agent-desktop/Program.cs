using FamilyShield.Agent.Services;

// Fail-safe: ensure orphaned proxy settings are cleaned up when the process exits.
AppDomain.CurrentDomain.ProcessExit += (_, _) => WebFilterProxy.ResetSystemProxyIfSet(8877);

// The identity must exist before the host starts: every hosted service assumes a paired device.
// Env overrides (API_BASE/DEVICE_JWT/DEVICE_ID/CHILD_ID) are applied inside AgentConfig.Load.
var exeDir = AppContext.BaseDirectory;
var config = AgentConfig.Load(exeDir);
if (config is null)
{
    if (!Environment.UserInteractive)
    {
        Console.Error.WriteLine(
            "OSRA agent is not paired. Run this exe interactively once to pair it, or create " +
            Path.Combine(exeDir, AgentConfig.FileName) + " with apiBase/deviceJwt/deviceId/childId.");
        return 2;
    }

    config = PairingDialog.Show();
    if (config is null)
    {
        Console.Error.WriteLine("Pairing cancelled; the agent will not start unpaired.");
        return 2;
    }
}

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddSingleton(config);

// Audit finding 1: a lock/bedtime/screen-time restriction needs a per-install parent PIN; there is
// no default. Say so at startup, because the enforcement services will refuse to arm (and log it).
if (ParentPinPolicy.Normalize(config.ParentPin) is null)
{
    Console.Error.WriteLine(
        "OSRA: WARNING — no parent PIN is configured. Lock, bedtime and screen-time will NOT arm " +
        $"until the parent sets one (parentPin in {AgentConfig.FileName}, or DESKTOP_PARENT_PIN " +
        "on the next start).");
}
builder.Services.AddHttpClient<ApiClient>(c =>
    // NOTE: config.ApiBase already carries the API_BASE env override (see AgentConfig.Load).
    c.BaseAddress = new Uri(config.ApiBase ?? "http://localhost:3000"));
builder.Services.AddHostedService<WebFilterProxy>();
builder.Services.AddHostedService<ProcessMonitor>();
builder.Services.AddHostedService<ScreenTimeEnforcer>();
builder.Services.AddHostedService<RuleSyncService>();
builder.Services.AddHostedService<TelemetryUploader>();
// Feature #14: the SOS hotkey calls RegisterHotKey (Windows-integration), so it is registered
// only when FS_SOS_HOTKEY=1 — the same env-gate pattern as FS_HTTPS_INSPECT (Feature #3).
if (SosHotkey.IsEnabled)
{
    builder.Services.AddHostedService<SosHotkey>();
}
builder.Services.AddSingleton<LocalRuleStore>();
builder.Build().Run();
return 0;
