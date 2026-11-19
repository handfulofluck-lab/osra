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
    private readonly TimeSpan _pollInterval;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _gate = new();
    private IHost? _runtime;
    private int _disposed;

    public RuntimeCoordinator(AgentConfig transportConfig, LocalRuleStore store, ITrayCommandSink sink,
        DesktopCapabilitiesStore capabilities, Func<AgentConfig?>? load = null, Func<AgentConfig, IHost>? hostFactory = null,
        TimeSpan? pollInterval = null)
    {
        _transportConfig = transportConfig;
        _store = store;
        _sink = sink;
        _capabilities = capabilities;
        _load = load ?? LoadConfiguration;
        _hostFactory = hostFactory ?? CreatePairedHost;
        _pollInterval = pollInterval ?? TimeSpan.FromSeconds(2);
    }

    public bool RuntimeStarted => Volatile.Read(ref _runtime) is not null;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (TryStartPairedRuntime()) return;
        using var timer = new PeriodicTimer(_pollInterval);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await timer.WaitForNextTickAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            if (TryStartPairedRuntime()) break;
        }
    }

    public Task StartPairedRuntime(int sessionId, CancellationToken cancellationToken)
    {
        TryStartPairedRuntime();
        return Task.CompletedTask;
    }

    private bool TryStartPairedRuntime()
    {
        lock (_gate)
        {
            if (_runtime is not null) return true;
            var loaded = _load();
            if (loaded is null) return false;
            _transportConfig.UpdateIdentityFrom(loaded);
            _runtime = _hostFactory(_transportConfig.ForService());
            _ = _runtime.StartAsync(_lifetime.Token);
            return true;
        }
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
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _lifetime.Cancel();
        _runtime?.Dispose();
        _lifetime.Dispose();
        base.Dispose();
    }
}
