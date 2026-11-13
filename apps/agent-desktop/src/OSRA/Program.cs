using FamilyShield.Agent.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

#if DEBUG
const bool allowEnvironmentOverrides = true;
#else
const bool allowEnvironmentOverrides = false;
#endif

try
{
    DesktopRuntime.MigrateDataFolder();
}
catch (Exception ex)
{
    Console.Error.WriteLine($"OSRA: could not migrate the legacy data folder: {ex.Message}");
    return 3;
}

var config = AgentConfig.Load(AppContext.BaseDirectory, allowEnvironmentOverrides);
var wasPaired = config is not null;
if (config is null)
{
    config = PairingDialog.Show();
    if (config is null)
    {
        Console.Error.WriteLine("Pairing cancelled; the tray will not start unpaired.");
        return 2;
    }
}

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});
DesktopRuntime.AddTray(builder.Services, config);
if (!wasPaired)
{
    var sink = builder.Services.BuildServiceProvider().GetRequiredService<ITrayCommandSink>();
    await sink.SendAsync(new TrayMessage(TrayMessageKind.pairing_complete));
}
await builder.Build().RunAsync();
return 0;
