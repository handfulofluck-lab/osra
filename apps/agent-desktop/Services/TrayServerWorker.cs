using System.IO.Pipes;
using System.Security.Principal;
using System.Text.Json;

namespace FamilyShield.Agent.Services;

public interface ITrayServerFactory
{
    ITrayServer Create(int sessionId, string userSid, int expectedPid);
}

public interface IPipeSquatProbe
{
    /// <summary>
    /// Best-effort probe returning only the bare executable image name (e.g. <c>powershell.exe</c>)
    /// of the process currently squatting on the session pipe, or null if unavailable.
    /// </summary>
    string? IdentifyHolderImageName(int sessionId);
}

internal sealed class WindowsPipeSquatProbe : IPipeSquatProbe
{
    private const int ProbeTimeoutMs = 250;

    public string? IdentifyHolderImageName(int sessionId)
    {
        try
        {
            // Anonymous impersonation prevents a hostile squatter from learning or impersonating
            // the connecting SYSTEM service token during the diagnostic probe.
            using var probe = new NamedPipeClientStream(
                ".", TrayPipeName.ForSession(sessionId), PipeDirection.InOut,
                PipeOptions.None, TokenImpersonationLevel.Anonymous);
            probe.Connect(ProbeTimeoutMs);
            var pid = TrayClientIdentity.ServerProcessId(probe);
            var imagePath = ProcessIdentityQuery.TryReadImagePath(pid);
            return TrayServerWorker.SanitizeImageName(imagePath);
        }
        catch (Exception)
        {
            return null;
        }
    }
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
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly IPipeSquatProbe _squatProbe;
    private readonly IReadOnlyList<TimeSpan> _pipeRetryBackoff;
    private static readonly TimeSpan DisposeWaitTimeout = TimeSpan.FromSeconds(5);
    internal static readonly TimeSpan[] DefaultPipeRetryBackoff =
    [
        TimeSpan.FromSeconds(5),
        TimeSpan.FromSeconds(10),
        TimeSpan.FromSeconds(20),
        TimeSpan.FromSeconds(40),
        TimeSpan.FromSeconds(60),
    ];
    private DateTime? _lastSosUtc;
    private readonly Dictionary<int, SessionSlot> _slots = new();
    private readonly Dictionary<int, PipeFailureState> _pipeFailures = new();
    private readonly object _gate = new();
    private bool _disposed;

    public TrayServerWorker(IInteractiveSessionSource sessions, ITrayServerFactory factory,
        ILogger<TrayServerWorker> log, ForegroundActivityAccumulator activity, ApiClient api,
        AgentConfig config, TrayServerEvents events, ITrayProcessRegistry? processRegistry = null,
        DesktopRestrictionState? restrictions = null, IDesktopSessionFallback? fallback = null,
        Func<DateTime>? clock = null, Func<TimeSpan, CancellationToken, Task>? delay = null,
        IPipeSquatProbe? squatProbe = null, IReadOnlyList<TimeSpan>? pipeRetryBackoff = null)
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
        _restrictions.PersistenceFailed += ReportPersistenceFailure;
        _fallback = fallback ?? new WtsSessionFallback();
        _clock = clock ?? (() => DateTime.UtcNow);
        _delay = delay ?? Task.Delay;
        _squatProbe = squatProbe ?? new WindowsPipeSquatProbe();
        _pipeRetryBackoff = pipeRetryBackoff ?? DefaultPipeRetryBackoff;
    }

    public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
    {
        var sessions = ListSessions();
        lock (_gate)
        {
            _restrictions.ObserveDevice(message, _clock());
            foreach (var session in sessions.Where(session => session.SessionId > 0 && session.IsActive))
                _restrictions.Observe(session.SessionId, message, _clock());
            foreach (var slot in _slots.Values) slot.Enqueue(message);
        }
        return Task.CompletedTask;
    }

    public void Synchronize()
    {
        var active = ListSessions().Where(s => s.SessionId > 0 && s.IsActive).GroupBy(s => s.SessionId);
        foreach (var group in active)
        {
            var session = group.First();
            lock (_gate)
            {
                if (_disposed) return;
                try
                {
                    if (_processRegistry?.ProcessIdForSession(session.SessionId) is not int expectedPid) continue;
                    IReadOnlyList<TrayMessage>? pending = null;
                    _slots.TryGetValue(session.SessionId, out var existing);
                    if (existing is not null)
                    {
                        if (!existing.IsCompleted) continue;
                        pending = existing.PendingMessages();
                    }
                    var now = _clock();
                    if (_pipeFailures.TryGetValue(session.SessionId, out var failureState) && now < failureState.NextRetryUtc)
                        continue;

                    ITrayServer server;
                    try
                    {
                        server = _factory.Create(session.SessionId, session.UserSid, expectedPid);
                        _pipeFailures.Remove(session.SessionId);
                    }
                    catch (Exception ex)
                    {
                        var failureCount = (failureState?.Count ?? 0) + 1;
                        var backoff = _pipeRetryBackoff.Count == 0
                            ? TimeSpan.Zero
                            : _pipeRetryBackoff[Math.Min(failureCount - 1, _pipeRetryBackoff.Count - 1)];
                        _pipeFailures[session.SessionId] = new PipeFailureState(failureCount, now + backoff);

                        var squatterImage = SanitizeImageName(_squatProbe.IdentifyHolderImageName(session.SessionId));
                        _log.LogError(ex,
                            "Could not create the tray pipe for session {SessionId} (failure {FailureCount}, holder {SquatterImage})",
                            session.SessionId, failureCount, squatterImage ?? "unknown");
                        if (_restrictions.RecordPipeFailure(session.SessionId))
                        {
                            var metadata = new Dictionary<string, object>
                            {
                                ["type"] = "tray_pipe_create_failed",
                                ["failureCount"] = failureCount,
                            };
                            if (squatterImage is not null) metadata["squatterImage"] = squatterImage;
                            _ = PostTamperAlert("tray_pipe_create_failed",
                                "Part of OSRA could not start on the computer. If a lock or limit is active and this continues, OSRA will lock the computer to keep it protected.",
                                extraMetadata: metadata);
                        }
                        continue;
                    }
                    if (existing is not null)
                    {
                        existing.Dispose();
                        _slots.Remove(session.SessionId);
                    }
                    var slot = new SessionSlot(session, server, HandleMessage, _log, _restrictions, _clock);
                    if (pending is not null)
                    {
                        foreach (var message in pending) slot.Enqueue(message);
                    }
                    _slots.Add(session.SessionId, slot);
                    _ = slot.RunAsync();
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "Could not supervise tray pipe session {SessionId}", session.SessionId);
                }
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
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Could not supervise tray pipe sessions");
            }
            try
            {
                await EnforceFallback(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
            catch (Exception ex)
            {
                _log.LogError(ex, "Could not enforce the offline fallback");
            }
            try
            {
                await _delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    internal async Task EnforceFallback(CancellationToken cancellationToken = default)
    {
        foreach (var session in ListSessions().Where(s => s.SessionId > 0 && s.IsActive))
        {
            try
            {
                if (!_restrictions.NeedsFallback(session.SessionId, _clock())) continue;
                await _fallback.LockWorkstation(session.SessionId);
                if (_restrictions.MarkFallback(session.SessionId, _clock()))
                {
                    await PostTamperAlert("tray_offline_fallback",
                        "Part of OSRA stopped running on the computer while a lock or limit was active, so OSRA locked the computer. This can happen if someone closed it.");
                }
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Could not enforce the offline fallback for session {SessionId}", session.SessionId);
            }
        }
    }

    private IReadOnlyList<InteractiveSession> ListSessions()
    {
        try
        {
            return _sessions.List();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Could not enumerate interactive sessions");
            return [];
        }
    }

    private void ReportPersistenceFailure() => _ = PostTamperAlert("restriction_store_write_failed",
        "OSRA could not save the current lock or limit on the computer. It is still applied, and OSRA keeps trying to save it.",
        _restrictions.RestoredUnreadable ? "critical" : "high", "OSRA could not save a setting on the computer");

    private Task PostTamperAlert(string type, string body, string severity = "critical",
        string title = "Protection on the computer was interrupted",
        Dictionary<string, object>? extraMetadata = null)
    {
        var metadata = extraMetadata ?? new Dictionary<string, object> { ["type"] = type };
        metadata["type"] = type;
        return _api.PostAlert(new AlertDto
        {
            DeviceId = _config.DeviceId,
            ChildId = _config.ChildId,
            Severity = severity,
            Category = "tamper",
            Title = title,
            Body = body,
            Metadata = metadata,
        });
    }

    /// <summary>
    /// Strips any directory path (preventing username/PII leakage) and clamps to a safe bare
    /// executable name for count-only squat diagnostics (#1115).
    /// </summary>
    internal static string? SanitizeImageName(string? imagePath)
    {
        if (string.IsNullOrWhiteSpace(imagePath)) return null;
        var trimmed = imagePath.Trim();
        var sep = trimmed.LastIndexOfAny(['\\', '/']);
        var fileName = sep >= 0 ? trimmed[(sep + 1)..] : trimmed;
        if (fileName.Length == 0) return null;
        Span<char> clean = stackalloc char[Math.Min(fileName.Length, 64)];
        var len = 0;
        foreach (var ch in fileName)
        {
            if (len == clean.Length) break;
            if (char.IsAsciiLetterOrDigit(ch) || ch is '.' or '-' or '_' or ' ')
                clean[len++] = ch;
        }
        var result = new string(clean[..len]).Trim();
        return result.Length == 0 ? null : result;
    }

    private sealed record PipeFailureState(int Count, DateTime NextRetryUtc);

    private async Task<TrayMessage?> HandleMessage(int sessionId, TrayMessage message, CancellationToken cancellationToken)
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
                    return new TrayMessage(TrayMessageKind.sos_result,
                        JsonSerializer.SerializeToElement(new { accepted = true }));
                }
                var accepted = await _api.PostAlert(SosHotkey.BuildAlert(_config), cancellationToken);
                if (accepted) _lastSosUtc = now;
                return new TrayMessage(TrayMessageKind.sos_result,
                    JsonSerializer.SerializeToElement(new { accepted }));
            case TrayMessageKind.pairing_complete:
                await _events.PairingComplete(sessionId, cancellationToken);
                break;
            case TrayMessageKind.capabilities:
                await _events.Capabilities(message.Payload!.Value, cancellationToken);
                break;
        }
        return null;
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await base.StopAsync(cancellationToken);
        var slots = DetachSlots();
        foreach (var slot in slots) slot.RequestStop();
        await Task.WhenAll(slots.Select(slot => slot.StopAsync(cancellationToken)));
    }

    public override void Dispose()
    {
        _restrictions.PersistenceFailed -= ReportPersistenceFailure;
        var slots = DetachSlots(markDisposed: true);
        foreach (var slot in slots) slot.RequestStop();
        foreach (var slot in slots) slot.Dispose();
        base.Dispose();
    }

    private List<SessionSlot> DetachSlots(bool markDisposed = false)
    {
        lock (_gate)
        {
            if (markDisposed) _disposed = true;
            var slots = _slots.Values.ToList();
            _slots.Clear();
            return slots;
        }
    }

    internal sealed class SessionSlot
    {
        private readonly InteractiveSession _session;
        private readonly ITrayServer _server;
        private readonly Func<int, TrayMessage, CancellationToken, Task<TrayMessage?>> _handle;
        private readonly ILogger<TrayServerWorker> _log;
        private readonly DesktopRestrictionState _restrictions;
        private readonly Func<DateTime> _clock;
        private readonly Queue<TrayMessage> _responses = new();
        private readonly Queue<TrayMessage> _pending = new();
        private readonly object _gate = new();
        private readonly object _stopGate = new();
        private readonly CancellationTokenSource _stop = new();
        private Task? _runTask;
        private bool _stopDisposed;
        private volatile bool _completed;

        public int SessionId => _session.SessionId;
        public bool IsCompleted => _completed;

        public SessionSlot(InteractiveSession session, ITrayServer server,
            Func<int, TrayMessage, CancellationToken, Task<TrayMessage?>> handle, ILogger<TrayServerWorker> log,
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
                if (message.Kind == TrayMessageKind.sos_result)
                {
                    _responses.Enqueue(message);
                    return;
                }
                if (_pending.Count >= 32) _pending.Dequeue();
                _pending.Enqueue(message);
            }
        }

        public Task RunAsync(CancellationToken cancellationToken = default)
        {
            lock (_gate)
            {
                _runTask ??= RunCoreAsync(cancellationToken);
                return _runTask;
            }
        }

        private async Task RunCoreAsync(CancellationToken cancellationToken)
        {
            CancellationTokenSource? linked = null;
            TrayPipeConnection? connection = null;
            try
            {
                lock (_stopGate)
                {
                    if (_stopDisposed) return;
                    linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _stop.Token);
                }
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
                    RequestStop();
                    try { linked?.Cancel(); } catch (ObjectDisposedException) { }
                    if (connection is not null)
                    {
                        _restrictions.MarkDisconnected(_session.SessionId, _clock());
                        await connection.DisposeAsync();
                    }
                    await _server.DisposeAsync();
                    linked?.Dispose();
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
                var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToService,
                    Timeout.InfiniteTimeSpan, cancellationToken);
                if (await _handle(_session.SessionId, message, cancellationToken) is { } response)
                    Enqueue(response);
            }
        }

        private async Task WriteOutgoing(TrayPipeConnection connection, CancellationToken cancellationToken)
        {
            while (true)
            {
                TrayMessage? pending;
                bool response;
                lock (_gate)
                {
                    response = _responses.Count > 0;
                    pending = response ? _responses.Peek() : _pending.Count > 0 ? _pending.Peek() : null;
                }
                if (pending is null)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                    continue;
                }
                await TrayProtocol.WriteAsync(connection.Stream, pending, TrayDirection.ToTray, cancellationToken);
                lock (_gate)
                {
                    var queue = response ? _responses : _pending;
                    if (queue.Count > 0 && ReferenceEquals(queue.Peek(), pending)) queue.Dequeue();
                }
            }
        }

        public IReadOnlyList<TrayMessage> PendingMessages()
        {
            lock (_gate) return _responses.Concat(_pending).ToArray();
        }

        public void RequestStop()
        {
            lock (_stopGate)
            {
                if (_stopDisposed) return;
                _stop.Cancel();
            }
        }

        public async Task StopAsync(CancellationToken cancellationToken = default)
        {
            RequestStop();
            Task? runTask;
            lock (_gate) runTask = _runTask;
            if (runTask is not null)
            {
                await runTask.WaitAsync(cancellationToken);
                DisposeStop();
                return;
            }
            if (TryBeginStopDispose())
                await _server.DisposeAsync();
        }

        public void Dispose()
        {
            RequestStop();
            Task? runTask;
            lock (_gate) runTask = _runTask;
            if (runTask is not null)
            {
                try
                {
                    if (runTask.Wait(DisposeWaitTimeout))
                        DisposeStop();
                }
                catch (AggregateException)
                {
                    DisposeStop();
                }
                return;
            }
            if (TryBeginStopDispose())
            {
                try { _server.DisposeAsync().AsTask().Wait(DisposeWaitTimeout); }
                catch (AggregateException) { }
            }
        }

        private void DisposeStop()
        {
            lock (_stopGate)
            {
                if (_stopDisposed) return;
                _stopDisposed = true;
                _stop.Dispose();
            }
        }

        private bool TryBeginStopDispose()
        {
            lock (_stopGate)
            {
                if (_stopDisposed) return false;
                _stopDisposed = true;
                _stop.Dispose();
                return true;
            }
        }
    }
}
