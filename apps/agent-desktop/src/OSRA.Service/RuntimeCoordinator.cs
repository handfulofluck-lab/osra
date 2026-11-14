using FamilyShield.Agent.Services;

namespace OSRA.Service;

internal sealed class RuntimeCoordinator : BackgroundService
{
    private readonly AgentConfig _transportConfig;
    private readonly LocalRuleStore _store;
    private readonly ITrayCommandSink _sink;
    private readonly DesktopCapabilitiesStore _capabilities;
    private readonly Func<AgentConfig?> _load;
    private readonly Func<AgentConfig, IHost> _hostFactory;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _gate = new();
    private IHost? _runtime;

    public RuntimeCoordinator(AgentConfig transportConfig, LocalRuleStore store, ITrayCommandSink sink,
        DesktopCapabilitiesStore capabilities, Func<AgentConfig?>? load = null, Func<AgentConfig, IHost>? hostFactory = null)
    {
        _transportConfig = transportConfig;
        _store = store;
        _sink = sink;
        _capabilities = capabilities;
        _load = load ?? LoadConfiguration;
        _hostFactory = hostFactory ?? CreatePairedHost;
    }

    public bool RuntimeStarted => _runtime is not null;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
        }
        catch (OperationCanceledException)
        {
        }
    }

    public Task StartPairedRuntime(int sessionId, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (_runtime is not null) return Task.CompletedTask;
            var loaded = _load();
            if (loaded is null) return Task.CompletedTask;
            _transportConfig.UpdateIdentityFrom(loaded);
            _runtime = _hostFactory(_transportConfig.ForService());
            _ = _runtime.StartAsync(_lifetime.Token);
        }
        return Task.CompletedTask;
    }

    private AgentConfig? LoadConfiguration()
    {
#if DEBUG
        const bool allowEnvironmentOverrides = true;
#else
        const bool allowEnvironmentOverrides = false;
#endif
        return AgentConfig.Load(AppContext.BaseDirectory, allowEnvironmentOverrides)?.ForService();
    }

    private IHost CreatePairedHost(AgentConfig config)
    {
        var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
        {
            ContentRootPath = AppContext.BaseDirectory,
        });
        DesktopRuntime.AddService(builder.Services, config, _sink, _store, _capabilities);
        return builder.Build();
    }

    public override void Dispose()
    {
        _lifetime.Cancel();
        _runtime?.Dispose();
        _lifetime.Dispose();
        base.Dispose();
    }
}
