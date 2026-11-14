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
    private TrayMessage? _awaitingSos;
    private DateTime _sosRetryAfter = DateTime.MinValue;

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
                if (_awaitingSos is null && _priority.Count == 0) _priority.Enqueue(message);
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
                using var connectionStop = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                var incoming = ReadIncoming(connection, connectionStop.Token);
                var outgoing = WriteOutgoing(connection, connectionStop.Token);
                var completed = await Task.WhenAny(incoming, outgoing);
                await connectionStop.CancelAsync();
                await completed;
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
                RequeueUnacknowledgedSos();
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
            if (message.Kind == TrayMessageKind.sos_result)
            {
                var accepted = message.Payload!.Value.GetProperty("accepted").GetBoolean();
                lock (_gate)
                {
                    if (_awaitingSos is { } sos)
                    {
                        _awaitingSos = null;
                        if (!accepted)
                        {
                            _priority.Enqueue(sos);
                            _sosRetryAfter = DateTime.UtcNow.AddSeconds(2);
                        }
                    }
                }
            }
            await _actions.HandleAsync(message, cancellationToken);
        }
    }

    private async Task WriteOutgoing(TrayPipeConnection connection, CancellationToken cancellationToken)
    {
        while (true)
        {
            TrayMessage? pending = null;
            var sos = false;
            lock (_gate)
            {
                if (_awaitingSos is null && _priority.Count > 0 && DateTime.UtcNow >= _sosRetryAfter)
                {
                    pending = _priority.Peek();
                    _awaitingSos = pending;
                    sos = true;
                }
                else if (_pending.Count > 0)
                {
                    pending = _pending.Peek();
                }
            }
            if (pending is null)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                continue;
            }
            try
            {
                await TrayProtocol.WriteAsync(connection.Stream, pending, TrayDirection.ToService, cancellationToken);
            }
            catch
            {
                if (sos) RequeueUnacknowledgedSos();
                throw;
            }
            lock (_gate)
            {
                var queue = sos ? _priority : _pending;
                if (queue.Count > 0 && ReferenceEquals(queue.Peek(), pending)) queue.Dequeue();
            }
        }
    }

    private void RequeueUnacknowledgedSos()
    {
        lock (_gate)
        {
            if (_awaitingSos is not { } sos) return;
            _awaitingSos = null;
            _priority.Enqueue(sos);
        }
    }
}
