using FamilyShield.Agent.Services;

namespace OSRA.Service;

internal static class ServiceHostComposition
{
    public static void ConfigureServices(IServiceCollection services, AgentConfig? config)
    {
        services.AddSingleton<IInteractiveSessionSource, WtsInteractiveSessionSource>();
        services.AddSingleton<INativeProcessLauncher, NativeProcessLauncher>();
        services.AddSingleton<ITrayLauncher, SessionProcess>();
        services.AddSingleton<TraySupervisor>();
        services.AddSingleton<ITrayProcessRegistry>(provider => provider.GetRequiredService<TraySupervisor>());
        services.AddHostedService(provider => provider.GetRequiredService<TraySupervisor>());
        if (config is not null)
        {
            DesktopRuntime.AddService(services, config);
            return;
        }

        var transportConfig = new AgentConfig { ApiBase = AgentConfig.ProductionApiBase };
        services.AddSingleton(transportConfig);
        services.AddSingleton<RuntimeCoordinator>();
        services.AddHostedService<RuntimeCoordinator>();
        services.AddSingleton(serviceProvider => new TrayServerEvents
        {
            PairingComplete = (sessionId, ct) => serviceProvider.GetRequiredService<RuntimeCoordinator>().StartPairedRuntime(sessionId, ct),
            Capabilities = (report, ct) =>
            {
                serviceProvider.GetRequiredService<DesktopCapabilitiesStore>().Update(report);
                return Task.CompletedTask;
            },
        });
        DesktopRuntime.AddServiceTransport(services, transportConfig,
            services.BuildServiceProvider().GetRequiredService<TrayServerEvents>());
    }
}
