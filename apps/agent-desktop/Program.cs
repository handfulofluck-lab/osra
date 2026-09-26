using FamilyShield.Agent.Services;

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
