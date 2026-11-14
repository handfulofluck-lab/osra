using System.Diagnostics;

namespace FamilyShield.Agent.Services;

public sealed class TrayPipeClientWorker : BackgroundService, ITrayCommandSink
{
    private readonly ITrayClient _client;
    private readonly TrayUserActions _actions;
    private readonly ILogger<TrayPipeClientWorker> _log;
    private readonly TrayConnectionState _state;
    private readonly Queue<TrayMessage> _pending = new();
    private readonly Queue<TrayMessage> _priority = new();
    private readonly object _gate = new();

    public TrayPipeClientWorker(ITrayClient client, TrayUserActions actions, ILogger<TrayPipeClientWorker> log,
        TrayConnectionState? state = null)
    {
        _client = client;
        _actions = actions;
        _log = log;
        _state = state ?? new TrayConnectionState();
    }

    public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (message.Kind == TrayMessageKind.sos)
            {
                _priority.Enqueue(message);
            }
            else
            {
                if (_pending.Count >= 32) _pending.Dequeue();
                _pending.Enqueue(message);
            }
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
                await TrayProtocol.WriteAsync(connection.Stream, new TrayMessage(TrayMessageKind.hello),
                    TrayDirection.ToService, stoppingToken);
                _state.IsConnected = true;
                var incoming = ReadIncoming(connection, stoppingToken);
                var outgoing = WriteOutgoing(connection, stoppingToken);
                await Task.WhenAny(incoming, outgoing);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Tray pipe disconnected; retrying");
            }
            finally
            {
                _state.IsConnected = false;
            }
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task ReadIncoming(TrayPipeConnection connection, CancellationToken cancellationToken)
    {
        while (true)
        {
            var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToTray,
                Timeout.InfiniteTimeSpan, cancellationToken);
            await _actions.HandleAsync(message, cancellationToken);
        }
    }

    private async Task WriteOutgoing(TrayPipeConnection connection, CancellationToken cancellationToken)
    {
        while (true)
        {
            TrayMessage? pending;
            lock (_gate)
            {
                pending = _priority.Count > 0 ? _priority.Dequeue() : _pending.Count > 0 ? _pending.Dequeue() : null;
            }
            if (pending is null)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                continue;
            }
            await TrayProtocol.WriteAsync(connection.Stream, pending, TrayDirection.ToService, cancellationToken);
        }
    }
}
