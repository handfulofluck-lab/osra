using System.Text.Json;

namespace FamilyShield.Agent.Services;

public sealed class DesktopRestrictionState
{
    private static readonly TimeSpan OfflineGrace = TimeSpan.FromSeconds(20);
    private readonly Dictionary<int, Entry> _entries = new();
    private readonly object _gate = new();

    public void Observe(int sessionId, TrayMessage message, DateTime utcNow)
    {
        lock (_gate)
        {
            if (message.Kind is TrayMessageKind.unlock or TrayMessageKind.resume)
            {
                _entries.Remove(sessionId);
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
        }
    }

    public IReadOnlyList<TrayMessage> MessagesFor(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(sessionId, out var entry)) return [];
            if (entry.WindDownAt is not null && entry.WindDownAt <= utcNow)
            {
                entry.Locked = true;
                entry.WindDownAt = null;
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
            if (!_entries.TryGetValue(sessionId, out var entry)) return;
            entry.Connected = true;
            entry.DisconnectedAt = null;
            entry.FallbackAt = null;
            entry.TamperAlerted = false;
        }
    }

    public void MarkDisconnected(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(sessionId, out var entry) || !entry.Connected) return;
            entry.Connected = false;
            entry.DisconnectedAt = utcNow;
        }
    }

    public bool NeedsFallback(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(sessionId, out var entry) || entry.Connected || entry.FallbackAt is not null)
                return false;
            if (!entry.Locked && !entry.Paused && entry.WindDownAt is null) return false;
            var since = entry.DisconnectedAt ?? entry.ObservedAt;
            return since is not null && utcNow - since >= OfflineGrace;
        }
    }

    public bool MarkFallback(int sessionId, DateTime utcNow)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(sessionId, out var entry) || entry.FallbackAt is not null) return false;
            entry.Locked = true;
            entry.WindDownAt = null;
            entry.FallbackAt = utcNow;
            if (entry.TamperAlerted) return false;
            entry.TamperAlerted = true;
            return true;
        }
    }

    public bool RecordPipeFailure(int sessionId)
    {
        lock (_gate)
        {
            var entry = EntryFor(sessionId, null);
            entry.Connected = false;
            if (entry.TamperAlerted) return false;
            entry.TamperAlerted = true;
            return true;
        }
    }

    private Entry EntryFor(int sessionId, DateTime? utcNow)
    {
        if (!_entries.TryGetValue(sessionId, out var entry))
            _entries[sessionId] = entry = new Entry();
        entry.ObservedAt ??= utcNow;
        return entry;
    }

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
