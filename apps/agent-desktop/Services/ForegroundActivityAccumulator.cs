namespace FamilyShield.Agent.Services;

public sealed class ForegroundActivityAccumulator
{
    private readonly LocalRuleStore _store;
    private readonly Dictionary<(int SessionId, string ProcessName), double> _seconds = new();
    private readonly Dictionary<int, DateTime> _lastSampleUtc = new();

    public ForegroundActivityAccumulator(LocalRuleStore store) => _store = store;

    public void AddSample(int sessionId, string processName, DateTime utcNow)
    {
        if (string.IsNullOrWhiteSpace(processName) || processName.Length > 260 ||
            processName.Equals("LockApp", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("LogonUI", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("idle", StringComparison.OrdinalIgnoreCase))
        {
            _lastSampleUtc.Remove(sessionId);
            return;
        }

        var normalized = RuleSetMapper.NormalizeProcessName(processName);
        if (!_lastSampleUtc.TryGetValue(sessionId, out var previous))
        {
            _lastSampleUtc[sessionId] = utcNow;
            return;
        }
        var elapsed = (utcNow - previous).TotalSeconds;
        _lastSampleUtc[sessionId] = utcNow;
        if (elapsed <= 0) return;

        var key = (sessionId, normalized);
        var seconds = _seconds.GetValueOrDefault(key) + elapsed;
        var minutes = (int)(seconds / 60);
        if (minutes > 0)
        {
            _store.AddAppMinutes(normalized, minutes);
            seconds -= minutes * 60;
        }
        _seconds[key] = seconds;
    }
}
