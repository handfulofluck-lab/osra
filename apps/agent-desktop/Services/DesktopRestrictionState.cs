using System.Text.Json;

namespace FamilyShield.Agent.Services;

public sealed class DesktopRestrictionState
{
    private static readonly TimeSpan OfflineGrace = TimeSpan.FromSeconds(20);
    private readonly Dictionary<int, Entry> _entries = new();
    private readonly IRestrictionStore? _store;
    private readonly object _gate = new();

    public DesktopRestrictionState(IRestrictionStore? store = null)
    {
        _store = store;
        if (_store is null) return;
        foreach (var saved in _store.Load())
        {
            _entries[saved.SessionId] = new Entry
            {
                Locked = saved.Locked,
                Paused = saved.Paused,
                WindDownAt = saved.WindDownAt,
                ObservedAt = saved.ObservedAt,
                DisconnectedAt = saved.DisconnectedAt,
                FallbackAt = saved.FallbackAt,
                TamperAlerted = saved.TamperAlerted,
            };
        }
    }

    public void ObserveDevice(TrayMessage message, DateTime utcNow) => Observe(0, message, utcNow);

    public void Observe(int sessionId, TrayMessage message, DateTime utcNow)
    {
        lock (_gate)
        {
            if (message.Kind is TrayMessageKind.unlock or TrayMessageKind.resume)
            {
                _entries.Remove(sessionId);
                Persist();
                return;
            }
            var minutes = message.Kind == TrayMessageKind.wind_down
                ? TrayCommandRouter.ParseMinutes(message.Payload) : 0;
            var isRestriction = message.Kind is TrayMessageKind.@lock or TrayMessageKind.pause ||
                                message.Kind == TrayMessageKind.wind_down && minutes > 0;
            if (!isRestriction) return;
            var entry = EntryFor(sessionId, utcNow);
            switch (message.Kind)
            {
                case TrayMessageKind.@lock:
                    entry.Locked = true;
                    break;
                case TrayMessageKind.pause:
                    entry.Paused = true;
                    break;
                case TrayMessageKind.wind_down:
                    entry.WindDownAt = utcNow.AddMinutes(minutes);
                    break;
            }
            Persist();
        }
    }

    public IReadOnlyList<TrayMessage> MessagesFor(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!TryGet(sessionId, out var entry)) return [];
            if (entry.WindDownAt is not null && entry.WindDownAt <= utcNow)
            {
                entry.Locked = true;
                entry.WindDownAt = null;
                Persist();
            }
            var messages = new List<TrayMessage>();
            if (entry.Locked) messages.Add(new TrayMessage(TrayMessageKind.@lock));
            if (entry.Paused) messages.Add(new TrayMessage(TrayMessageKind.pause));
            if (entry.WindDownAt is { } deadline)
            {
                var minutes = Math.Clamp((int)Math.Ceiling((deadline - utcNow).TotalMinutes), 1, 1440);
                messages.Add(new TrayMessage(TrayMessageKind.wind_down,
                    JsonSerializer.SerializeToElement(new { minutes })));
            }
            return messages;
        }
    }

    public void MarkConnected(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            var entry = EntryFor(sessionId, null);
            entry.Connected = true;
            entry.DisconnectedAt = null;
            entry.FallbackAt = null;
            entry.TamperAlerted = false;
            Persist();
        }
    }

    public void MarkDisconnected(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(sessionId, out var entry) || !entry.Connected) return;
            entry.Connected = false;
            entry.DisconnectedAt = utcNow;
            Persist();
        }
    }

    public bool NeedsFallback(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!TryGet(sessionId, out var entry) || entry.Connected) return false;
            if (!entry.Locked && !entry.Paused && entry.WindDownAt is null) return false;
            var since = entry.FallbackAt ?? entry.DisconnectedAt ?? entry.ObservedAt;
            return since is not null && utcNow - since >= OfflineGrace;
        }
    }

    public bool MarkFallback(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            var entry = EntryFor(sessionId, utcNow);
            entry.Locked = true;
            entry.WindDownAt = null;
            entry.FallbackAt = utcNow;
            if (entry.TamperAlerted)
            {
                Persist();
                return false;
            }
            entry.TamperAlerted = true;
            Persist();
            return true;
        }
    }

    public bool RecordPipeFailure(int sessionId)
    {
        lock (_gate)
        {
            var entry = EntryFor(sessionId, null);
            entry.Connected = false;
            if (entry.TamperAlerted)
            {
                Persist();
                return false;
            }
            entry.TamperAlerted = true;
            Persist();
            return true;
        }
    }

    private Entry EntryFor(int sessionId, DateTime? utcNow)
    {
        if (!_entries.TryGetValue(sessionId, out var entry))
        {
            entry = sessionId > 0 && _entries.TryGetValue(0, out var device) ? Clone(device) : new Entry();
            _entries[sessionId] = entry;
        }
        entry.ObservedAt ??= utcNow;
        return entry;
    }

    private bool TryGet(int sessionId, out Entry entry)
    {
        if (_entries.TryGetValue(sessionId, out entry!)) return true;
        if (sessionId > 0 && _entries.TryGetValue(0, out entry!)) return true;
        entry = null!;
        return false;
    }

    private void Persist()
    {
        if (_store is null) return;
        _store.Save(_entries.Select(pair => new SessionRestriction
        {
            SessionId = pair.Key,
            Locked = pair.Value.Locked,
            Paused = pair.Value.Paused,
            WindDownAt = pair.Value.WindDownAt,
            ObservedAt = pair.Value.ObservedAt,
            DisconnectedAt = pair.Value.DisconnectedAt,
            FallbackAt = pair.Value.FallbackAt,
            TamperAlerted = pair.Value.TamperAlerted,
        }).ToArray());
    }

    private static Entry Clone(Entry source) => new()
    {
        Locked = source.Locked,
        Paused = source.Paused,
        WindDownAt = source.WindDownAt,
        ObservedAt = source.ObservedAt,
        DisconnectedAt = source.DisconnectedAt,
        FallbackAt = source.FallbackAt,
        TamperAlerted = source.TamperAlerted,
    };

    private sealed class Entry
    {
        public bool Locked;
        public bool Paused;
        public DateTime? WindDownAt;
        public DateTime? ObservedAt;
        public DateTime? DisconnectedAt;
        public DateTime? FallbackAt;
        public bool Connected;
        public bool TamperAlerted;
    }
}
