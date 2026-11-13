using System.Diagnostics;

namespace FamilyShield.Agent.Services;

public sealed class TrayPipeClientWorker : BackgroundService, ITrayCommandSink
{
    private readonly ITrayClient _client;
    private readonly TrayUserActions _actions;
    private readonly ILogger<TrayPipeClientWorker> _log;
    private readonly Queue<TrayMessage> _pending = new();
    private readonly object _gate = new();

    public TrayPipeClientWorker(ITrayClient client, TrayUserActions actions, ILogger<TrayPipeClientWorker> log)
    {
        _client = client;
        _actions = actions;
        _log = log;
    }

    public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_pending.Count >= 32) _pending.Dequeue();
            _pending.Enqueue(message);
        }
        return Task.CompletedTask;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var session = Process.GetCurrentProcess().SessionId;
                await using var connection = await _client.ConnectAsync(session, stoppingToken);
                while (true)
                {
                    TrayMessage? pending;
                    lock (_gate) pending = _pending.Count > 0 ? _pending.Dequeue() : null;
                    if (pending is null) break;
                    await TrayProtocol.WriteAsync(connection.Stream, pending, TrayDirection.ToService, stoppingToken);
                }
                while (true)
                {
                    var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToTray, cancellationToken: stoppingToken);
                    await _actions.HandleAsync(message, stoppingToken);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Tray pipe disconnected; retrying");
                try { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken); }
                catch (OperationCanceledException) { break; }
            }
        }
    }
}
