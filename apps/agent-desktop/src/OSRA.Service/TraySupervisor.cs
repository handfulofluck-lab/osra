using FamilyShield.Agent.Services;

namespace OSRA.Service;

internal interface ITrayActivationGate
{
    bool IsReady { get; }
}

internal sealed class TraySupervisor : BackgroundService, ITrayProcessRegistry
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(15);
    private readonly IInteractiveSessionSource _sessions;
    private readonly ITrayLauncher _launcher;
    private readonly ITrayProcessDiscovery? _discovery;
    private readonly ILogger<TraySupervisor> _log;
    private readonly Func<bool> _isPaired;
    private readonly Dictionary<int, ITrayProcess> _processes = new();
    private readonly object _gate = new();

    public TraySupervisor(IInteractiveSessionSource sessions, ITrayLauncher launcher, ILogger<TraySupervisor> log,
        ITrayProcessDiscovery? discovery = null, ITrayActivationGate? activation = null)
        : this(sessions, launcher, log, discovery, activation is null ? null : () => activation.IsReady)
    {
    }

    internal TraySupervisor(IInteractiveSessionSource sessions, ITrayLauncher launcher, ILogger<TraySupervisor> log,
        ITrayProcessDiscovery? discovery, Func<bool>? isPaired)
    {
        _sessions = sessions;
        _launcher = launcher;
        _discovery = discovery ?? launcher as ITrayProcessDiscovery;
        _log = log;
        _isPaired = isPaired ?? (() => true);
    }

    public static IReadOnlyList<InteractiveSession> DesiredSessions(IEnumerable<InteractiveSession> sessions) =>
        sessions.Where(s => s.SessionId > 0 && s.IsActive).GroupBy(s => s.SessionId).Select(g => g.First()).ToArray();

    public int? ProcessIdForSession(int sessionId)
    {
        lock (_gate)
        {
            return _processes.TryGetValue(sessionId, out var process) && !process.HasExited ? process.ProcessId : null;
        }
    }

    public void Synchronize()
    {
        if (!_isPaired()) return;

        IReadOnlyList<InteractiveSession> sessions;
        try
        {
            sessions = _sessions.List();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Could not enumerate interactive sessions");
            return;
        }
        lock (_gate)
        {
            foreach (var session in DesiredSessions(sessions))
            {
                try
                {
                    if (_processes.TryGetValue(session.SessionId, out var running))
                    {
                        if (!running.HasExited) continue;
                        running.Dispose();
                        _processes.Remove(session.SessionId);
                    }
                    if (_discovery?.FindInstalledTray(session) is { } existing)
                    {
                        if (!existing.HasExited)
                        {
                            _processes[session.SessionId] = existing;
                            _log.LogInformation("Adopted the installed tray already running in session {SessionId}", session.SessionId);
                            continue;
                        }
                        existing.Dispose();
                    }
                    _processes[session.SessionId] = _launcher.StartInstalledTray(session);
                    _log.LogInformation("Started the installed tray in session {SessionId}", session.SessionId);
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "Could not supervise the installed tray in session {SessionId}", session.SessionId);
                }
            }
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(PollInterval);
        while (!stoppingToken.IsCancellationRequested)
        {
            Synchronize();
            try
            {
                await timer.WaitForNextTickAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    public override void Dispose()
    {
        lock (_gate)
        {
            foreach (var process in _processes.Values) process.Dispose();
            _processes.Clear();
        }
        base.Dispose();
    }
}
