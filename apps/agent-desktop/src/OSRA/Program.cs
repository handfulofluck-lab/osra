using System.ComponentModel;
using System.Diagnostics;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

#if DEBUG
const bool allowEnvironmentOverrides = true;
#else
const bool allowEnvironmentOverrides = false;
#endif

const string elevatedPairFlag = "--elevated-pair";
var isElevatedPair = Array.Exists(args, arg => string.Equals(arg, elevatedPairFlag, StringComparison.Ordinal));

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
    if (!AgentConfig.CanPersist(AppContext.BaseDirectory))
    {
        if (isElevatedPair || string.IsNullOrWhiteSpace(Environment.ProcessPath))
        {
            Console.Error.WriteLine("OSRA cannot write pairing configuration to the install folder.");
            return 2;
        }
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = Environment.ProcessPath,
                Arguments = elevatedPairFlag,
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = AppContext.BaseDirectory,
            });
            return 0;
        }
        catch (Win32Exception)
        {
            Console.Error.WriteLine("Administrator approval was cancelled; pairing was not started.");
            return 2;
        }
    }

    config = PairingDialog.Show();
    if (config is null)
    {
        Console.Error.WriteLine("Pairing cancelled; the tray will not start unpaired.");
        return 2;
    }

    if (isElevatedPair)
    {
        // Exit the temporary elevated pairing process so OSRA Service launches the standard session tray.
        return 0;
    }
}

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});
DesktopRuntime.AddTray(builder.Services, config);
var host = builder.Build();
if (!wasPaired)
    await host.Services.GetRequiredService<ITrayCommandSink>().SendAsync(new TrayMessage(TrayMessageKind.pairing_complete));
await host.RunAsync();
return 0;
