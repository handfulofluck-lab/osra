namespace FamilyShield.Agent.Services;

/// <summary>Dependency registration for the two OSRA hosts, with UI confined to the tray.</summary>
public static class DesktopRuntime
{
    public static void MigrateDataFolder() => DataFolder.MigrateOnce();

    public static IServiceCollection AddService(IServiceCollection services, AgentConfig config)
    {
        services.AddSingleton(config);
        services.AddHttpClient<ApiClient>(client => client.BaseAddress = new Uri(config.ApiBase ?? AgentConfig.ProductionApiBase));
        services.AddHostedService<WebFilterProxy>();
        services.AddHostedService<ProcessMonitor>();
        services.AddHostedService<RuleSyncService>();
        services.AddHostedService<TelemetryUploader>();
        services.AddSingleton<LocalRuleStore>();
        return services;
    }

    public static IServiceCollection AddTray(IServiceCollection services, AgentConfig config)
    {
        services.AddSingleton(config);
        services.AddHttpClient<ApiClient>(client => client.BaseAddress = new Uri(config.ApiBase ?? AgentConfig.ProductionApiBase));
        services.AddSingleton<LocalRuleStore>();
        services.AddHostedService<ScreenTimeEnforcer>();
        if (!config.AllowEnvironmentOverrides || SosHotkey.IsEnabled)
            services.AddHostedService<SosHotkey>();
        return services;
    }
}
