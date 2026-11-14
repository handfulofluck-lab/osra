namespace FamilyShield.Agent.Services;

/// <summary>Dependency registration for the two OSRA hosts, with UI confined to the tray.</summary>
public static class DesktopRuntime
{
    public static void MigrateDataFolder() => DataFolder.MigrateOnce();

    public static IServiceCollection AddServiceTransport(IServiceCollection services, AgentConfig config, TrayServerEvents events)
    {
        AddRestrictionState(services);
        services.AddSingleton(config);
        services.AddHttpClient<ApiClient>(client => client.BaseAddress = new Uri(config.ApiBase ?? AgentConfig.ProductionApiBase));
        services.AddSingleton<LocalRuleStore>();
        services.AddSingleton<ForegroundActivityAccumulator>();
        services.AddSingleton<DesktopCapabilitiesStore>();
        services.AddSingleton(events);
        services.AddSingleton<ITrayServerFactory, TrayPipeServerFactory>();
        services.AddSingleton<ITrayCommandSink, TrayServerWorker>();
        services.AddHostedService<TrayServerWorker>();
        return services;
    }

    public static IServiceCollection AddService(IServiceCollection services, AgentConfig config,
        ITrayCommandSink? transport = null, LocalRuleStore? store = null, DesktopCapabilitiesStore? capabilityStore = null)
    {
        AddRestrictionState(services);
        services.AddSingleton(config);
        services.AddHttpClient<ApiClient>(client => client.BaseAddress = new Uri(config.ApiBase ?? AgentConfig.ProductionApiBase));
        if (store is null) services.AddSingleton<LocalRuleStore>();
        else services.AddSingleton(store);
        if (capabilityStore is null) services.AddSingleton<DesktopCapabilitiesStore>();
        else services.AddSingleton(capabilityStore);
        if (transport is null)
        {
            services.AddSingleton<ForegroundActivityAccumulator>();
            services.AddSingleton(serviceProvider => new TrayServerEvents
            {
                Capabilities = (report, ct) =>
                {
                    serviceProvider.GetRequiredService<DesktopCapabilitiesStore>().Update(report);
                    return Task.CompletedTask;
                },
            });
            services.AddSingleton<ITrayServerFactory, TrayPipeServerFactory>();
            services.AddSingleton<ITrayCommandSink, TrayServerWorker>();
            services.AddHostedService<TrayServerWorker>();
        }
        else
        {
            services.AddSingleton(transport);
        }
        services.AddHostedService<WebFilterProxy>();
        services.AddHostedService<ProcessMonitor>();
        services.AddHostedService<RuleSyncService>();
        services.AddHostedService<TelemetryUploader>();
        return services;
    }

    private static void AddRestrictionState(IServiceCollection services)
    {
        if (services.Any(descriptor => descriptor.ServiceType == typeof(IRestrictionStore))) return;
        services.AddSingleton<IRestrictionStore, FileDesktopRestrictionStore>();
        services.AddSingleton<DesktopRestrictionState>();
    }

    public static IServiceCollection AddTray(IServiceCollection services, AgentConfig config)
    {
        services.AddSingleton(config);
        services.AddHttpClient<ApiClient>(client => client.BaseAddress = new Uri(config.ApiBase ?? AgentConfig.ProductionApiBase));
        services.AddSingleton<LocalRuleStore>();
        services.AddSingleton<TrayConnectionState>();
        services.AddSingleton<TrayUserActions>();
        services.AddSingleton<ITrayClient, TrayPipeClient>();
        services.AddSingleton<ITrayCommandSink, TrayPipeClientWorker>();
        services.AddHostedService<TrayPipeClientWorker>();
        services.AddHostedService<ForegroundActivityReporter>();
        services.AddHostedService<DesktopCapabilitiesReporter>();
        services.AddHostedService<ScreenTimeEnforcer>();
        if (!config.AllowEnvironmentOverrides || SosHotkey.IsEnabled)
            services.AddHostedService<SosHotkey>();
        return services;
    }
}
