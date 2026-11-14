using FamilyShield.Agent.Services;

namespace OSRA.Service;

internal sealed class TraySupervisor : BackgroundService, ITrayProcessRegistry
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(15);
    private readonly IInteractiveSessionSource _sessions;
    private readonly ITrayLauncher _launcher;
    private readonly ILogger<TraySupervisor> _log;
    private readonly Dictionary<int, ITrayProcess> _processes = new();
    private readonly object _gate = new();

    public TraySupervisor(IInteractiveSessionSource sessions, ITrayLauncher launcher, ILogger<TraySupervisor> log)
    {
        _sessions = sessions;
        _launcher = launcher;
        _log = log;
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
        lock (_gate)
        {
            foreach (var session in DesiredSessions(_sessions.List()))
            {
                if (_processes.TryGetValue(session.SessionId, out var running))
                {
                    if (!running.HasExited) continue;
                    running.Dispose();
                    _processes.Remove(session.SessionId);
                }

                try
                {
                    _processes[session.SessionId] = _launcher.StartInstalledTray(session);
                    _log.LogInformation("Started the installed tray in session {SessionId}", session.SessionId);
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "Could not start the installed tray in session {SessionId}", session.SessionId);
                }
            }
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(PollInterval);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                Synchronize();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Tray supervision pass failed");
            }
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
