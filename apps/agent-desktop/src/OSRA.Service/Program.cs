using FamilyShield.Agent.Services;
using OSRA.Service;

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

var config = AgentConfig.Load(AppContext.BaseDirectory, allowEnvironmentOverrides)?.ForService();
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});
builder.Services.AddWindowsService(options => options.ServiceName = "OSRA Service");
ServiceHostComposition.ConfigureServices(builder.Services, config);
if (config is not null)
    AppDomain.CurrentDomain.ProcessExit += (_, _) => WebFilterProxy.ResetSystemProxyIfSet(8877);
await builder.Build().RunAsync();
return 0;
