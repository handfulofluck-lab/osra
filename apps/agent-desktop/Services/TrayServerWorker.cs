using System.Text.Json;

namespace FamilyShield.Agent.Services;

public interface ITrayServerFactory
{
    ITrayServer Create(int sessionId, string userSid);
}

public sealed class TrayPipeServerFactory : ITrayServerFactory
{
    public ITrayServer Create(int sessionId, string userSid) => new TrayPipeServer(sessionId, userSid);
}

public sealed class TrayServerEvents
{
    public Func<int, CancellationToken, Task> PairingComplete { get; init; } = (_, _) => Task.CompletedTask;
    public Func<JsonElement, CancellationToken, Task> Capabilities { get; init; } = (_, _) => Task.CompletedTask;
}

public sealed class TrayServerWorker : BackgroundService, ITrayCommandSink
{
    private readonly IInteractiveSessionSource _sessions;
    private readonly ITrayServerFactory _factory;
    private readonly ILogger<TrayServerWorker> _log;
    private readonly ForegroundActivityAccumulator _activity;
    private readonly ApiClient _api;
    private readonly AgentConfig _config;
    private readonly TrayServerEvents _events;
    private readonly Dictionary<int, SessionSlot> _slots = new();
    private readonly object _gate = new();

    public TrayServerWorker(IInteractiveSessionSource sessions, ITrayServerFactory factory,
        ILogger<TrayServerWorker> log, ForegroundActivityAccumulator activity, ApiClient api,
        AgentConfig config, TrayServerEvents events)
    {
        _sessions = sessions;
        _factory = factory;
        _log = log;
        _activity = activity;
        _api = api;
        _config = config;
        _events = events;
    }

    public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            foreach (var slot in _slots.Values) slot.Enqueue(message);
        }
        return Task.CompletedTask;
    }

    public void Synchronize()
    {
        var active = _sessions.List().Where(s => s.SessionId > 0 && s.IsActive).GroupBy(s => s.SessionId);
        foreach (var group in active)
        {
            var session = group.First();
            lock (_gate)
            {
                if (_slots.ContainsKey(session.SessionId)) continue;
                var slot = new SessionSlot(session, _factory.Create(session.SessionId, session.UserSid), HandleMessage, _log);
                _slots.Add(session.SessionId, slot);
                _ = slot.RunAsync();
            }
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                Synchronize();
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Could not supervise a tray pipe session");
            }
        }
    }

    private async Task HandleMessage(int sessionId, TrayMessage message, CancellationToken cancellationToken)
    {
        switch (message.Kind)
        {
            case TrayMessageKind.foreground_sample:
                _activity.AddSample(sessionId, message.Payload!.Value.GetProperty("processName").GetString()!, DateTime.UtcNow);
                break;
            case TrayMessageKind.sos:
                await _api.PostAlert(SosHotkey.BuildAlert(_config), cancellationToken);
                break;
            case TrayMessageKind.pairing_complete:
                await _events.PairingComplete(sessionId, cancellationToken);
                break;
            case TrayMessageKind.capabilities:
                await _events.Capabilities(message.Payload!.Value, cancellationToken);
                break;
        }
    }

    public override void Dispose()
    {
        lock (_gate)
        {
            foreach (var slot in _slots.Values) slot.Dispose();
            _slots.Clear();
        }
        base.Dispose();
    }

    internal sealed class SessionSlot
    {
        private readonly InteractiveSession _session;
        private readonly ITrayServer _server;
        private readonly Func<int, TrayMessage, CancellationToken, Task> _handle;
        private readonly ILogger<TrayServerWorker> _log;
        private readonly Queue<TrayMessage> _pending = new();
        private readonly object _gate = new();
        private readonly CancellationTokenSource _stop = new();

        public SessionSlot(InteractiveSession session, ITrayServer server,
            Func<int, TrayMessage, CancellationToken, Task> handle, ILogger<TrayServerWorker> log)
        {
            _session = session;
            _server = server;
            _handle = handle;
            _log = log;
        }

        public void Enqueue(TrayMessage message)
        {
            lock (_gate)
            {
                if (_pending.Count >= 32) _pending.Dequeue();
                _pending.Enqueue(message);
            }
        }

        public async Task RunAsync(CancellationToken cancellationToken = default)
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _stop.Token);
            TrayPipeConnection? connection = null;
            try
            {
                connection = await _server.AcceptAsync(linked.Token);
                while (true)
                {
                    TrayMessage? pending;
                    lock (_gate) pending = _pending.Count > 0 ? _pending.Dequeue() : null;
                    if (pending is null) break;
                    await TrayProtocol.WriteAsync(connection.Stream, pending, TrayDirection.ToTray, linked.Token);
                }
                while (true)
                {
                    var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToService, cancellationToken: linked.Token);
                    await _handle(_session.SessionId, message, linked.Token);
                }
            }
            catch (EndOfStreamException) { }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Tray pipe session ended");
            }
            finally
            {
                if (connection is not null) await connection.DisposeAsync();
                await _server.DisposeAsync();
            }
        }

        public void Dispose() => _stop.Cancel();
    }
}
