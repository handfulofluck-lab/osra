using FamilyShield.Agent.Services;

namespace OSRA.Service;

internal static class ServiceHostComposition
{
    public static void ConfigureServices(IServiceCollection services, AgentConfig? config)
    {
        services.AddSingleton<IInteractiveSessionSource, WtsInteractiveSessionSource>();
        services.AddSingleton<INativeProcessLauncher, NativeProcessLauncher>();
        services.AddSingleton<ITrayLauncher, SessionProcess>();
        services.AddHostedService<TraySupervisor>();
        if (config is not null) DesktopRuntime.AddService(services, config);
    }
}
