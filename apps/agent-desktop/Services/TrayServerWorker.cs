using System.Text.Json;

namespace FamilyShield.Agent.Services;

public interface ITrayServerFactory
{
    ITrayServer Create(int sessionId, string userSid, int expectedPid);
}

public sealed class TrayPipeServerFactory : ITrayServerFactory
{
    public ITrayServer Create(int sessionId, string userSid, int expectedPid) => new TrayPipeServer(sessionId, userSid, expectedPid);
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
    private readonly ITrayProcessRegistry? _processRegistry;
    private readonly DesktopRestrictionState _restrictions;
    private readonly IDesktopSessionFallback _fallback;
    private readonly Func<DateTime> _clock;
    private DateTime? _lastSosUtc;
    private readonly Dictionary<int, SessionSlot> _slots = new();
    private readonly object _gate = new();

    public TrayServerWorker(IInteractiveSessionSource sessions, ITrayServerFactory factory,
        ILogger<TrayServerWorker> log, ForegroundActivityAccumulator activity, ApiClient api,
        AgentConfig config, TrayServerEvents events, ITrayProcessRegistry? processRegistry = null,
        DesktopRestrictionState? restrictions = null, IDesktopSessionFallback? fallback = null,
        Func<DateTime>? clock = null)
    {
        _sessions = sessions;
        _factory = factory;
        _log = log;
        _activity = activity;
        _api = api;
        _config = config;
        _events = events;
        _processRegistry = processRegistry;
        _restrictions = restrictions ?? new DesktopRestrictionState();
        _fallback = fallback ?? new WtsSessionFallback();
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            _restrictions.ObserveDevice(message, _clock());
            foreach (var session in _sessions.List().Where(session => session.SessionId > 0 && session.IsActive))
                _restrictions.Observe(session.SessionId, message, _clock());
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
                if (_processRegistry?.ProcessIdForSession(session.SessionId) is not int expectedPid) continue;
                IReadOnlyList<TrayMessage>? pending = null;
                if (_slots.TryGetValue(session.SessionId, out var existing))
                {
                    if (!existing.IsCompleted) continue;
                    pending = existing.PendingMessages();
                    existing.Dispose();
                    _slots.Remove(session.SessionId);
                }
                ITrayServer server;
                try
                {
                    server = _factory.Create(session.SessionId, session.UserSid, expectedPid);
                }
                catch
                {
                    if (_restrictions.RecordPipeFailure(session.SessionId))
                        _ = PostTamperAlert("tray_pipe_create_failed",
                            "The tray pipe could not be created. OSRA Service will protect a restricted session if it stays unavailable.");
                    throw;
                }
                var slot = new SessionSlot(session, server, HandleMessage, _log, _restrictions, _clock);
                if (pending is not null)
                {
                    foreach (var message in pending) slot.Enqueue(message);
                }
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
            await EnforceFallback(stoppingToken);
        }
    }

    internal async Task EnforceFallback(CancellationToken cancellationToken = default)
    {
        foreach (var session in _sessions.List().Where(s => s.SessionId > 0 && s.IsActive))
        {
            if (!_restrictions.NeedsFallback(session.SessionId, _clock())) continue;
            try
            {
                await _fallback.LockWorkstation(session.SessionId);
                if (_restrictions.MarkFallback(session.SessionId, _clock()))
                {
                    await PostTamperAlert("tray_offline_fallback",
                        "No verified tray was connected for 20 seconds during a restriction. OSRA Service locked the session.");
                }
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Could not enforce the offline fallback for session {SessionId}", session.SessionId);
            }
        }
    }

    private Task PostTamperAlert(string type, string body) => _api.PostAlert(new AlertDto
    {
        DeviceId = _config.DeviceId,
        ChildId = _config.ChildId,
        Severity = "critical",
        Category = "tamper",
        Title = "Windows tray protection was interrupted",
        Body = body,
        Metadata = new Dictionary<string, object> { ["type"] = type },
    });

    private async Task HandleMessage(int sessionId, TrayMessage message, CancellationToken cancellationToken)
    {
        switch (message.Kind)
        {
            case TrayMessageKind.foreground_sample:
                _activity.AddSample(sessionId, message.Payload!.Value.GetProperty("processName").GetString()!, DateTime.UtcNow);
                break;
            case TrayMessageKind.sos:
                var now = _clock();
                if (_lastSosUtc is { } lastSos && now - lastSos < TimeSpan.FromSeconds(60))
                {
                    _log.LogInformation("SOS ignored inside the per-device 60-second window");
                    break;
                }
                _lastSosUtc = now;
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
        private readonly DesktopRestrictionState _restrictions;
        private readonly Func<DateTime> _clock;
        private readonly Queue<TrayMessage> _pending = new();
        private readonly object _gate = new();
        private readonly CancellationTokenSource _stop = new();
        private volatile bool _completed;

        public int SessionId => _session.SessionId;
        public bool IsCompleted => _completed;

        public SessionSlot(InteractiveSession session, ITrayServer server,
            Func<int, TrayMessage, CancellationToken, Task> handle, ILogger<TrayServerWorker> log,
            DesktopRestrictionState? restrictions = null, Func<DateTime>? clock = null)
        {
            _session = session;
            _server = server;
            _handle = handle;
            _log = log;
            _restrictions = restrictions ?? new DesktopRestrictionState();
            _clock = clock ?? (() => DateTime.UtcNow);
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
                _restrictions.MarkConnected(_session.SessionId, _clock());
                foreach (var message in _restrictions.MessagesFor(_session.SessionId, _clock()))
                    await TrayProtocol.WriteAsync(connection.Stream, message, TrayDirection.ToTray, linked.Token);
                var incoming = ReadIncoming(connection, linked.Token);
                var outgoing = WriteOutgoing(connection, linked.Token);
                var completed = await Task.WhenAny(incoming, outgoing);
                await completed;
            }
            catch (EndOfStreamException) { }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Tray pipe session ended");
            }
            finally
            {
                try
                {
                    _stop.Cancel();
                    if (connection is not null)
                    {
                        _restrictions.MarkDisconnected(_session.SessionId, _clock());
                        await connection.DisposeAsync();
                    }
                    await _server.DisposeAsync();
                }
                finally
                {
                    _completed = true;
                }
            }
        }

        private async Task ReadIncoming(TrayPipeConnection connection, CancellationToken cancellationToken)
        {
            while (true)
            {
                var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToService, cancellationToken: cancellationToken);
                await _handle(_session.SessionId, message, cancellationToken);
            }
        }

        private async Task WriteOutgoing(TrayPipeConnection connection, CancellationToken cancellationToken)
        {
            while (true)
            {
                TrayMessage? pending;
                lock (_gate) pending = _pending.Count > 0 ? _pending.Peek() : null;
                if (pending is null)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                    continue;
                }
                await TrayProtocol.WriteAsync(connection.Stream, pending, TrayDirection.ToTray, cancellationToken);
                lock (_gate)
                {
                    if (_pending.Count > 0 && ReferenceEquals(_pending.Peek(), pending)) _pending.Dequeue();
                }
            }
        }

        public IReadOnlyList<TrayMessage> PendingMessages()
        {
            lock (_gate) return _pending.ToArray();
        }

        public void Dispose() => _stop.Cancel();
    }
}
