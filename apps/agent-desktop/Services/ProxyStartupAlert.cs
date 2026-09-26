namespace FamilyShield.Agent.Services;

/// <summary>
/// Review #26 fail-open startup alert: when the WebFilterProxy cannot start (port already bound,
/// Internet Settings registry locked, ...) the agent keeps running with the child UNFILTERED, so
/// the parent must be told via a throttled tamper alert. The decision is pure so the
/// throttle/paired/failed logic is xunit-testable.
/// </summary>
public static class ProxyStartupAlert
{
    /// <summary>At most one 'proxy failed to start' alert per hour — the agent log records every occurrence.</summary>
    public static readonly TimeSpan Throttle = TimeSpan.FromHours(1);

    /// <summary>
    /// True when a 'proxy failed to start' tamper alert must be posted: the proxy is NOT running
    /// because startup failed, the agent is paired (an unpaired agent has no parent to alert), and
    /// the hourly throttle has elapsed since <paramref name="lastAlertUtc"/>.
    /// </summary>
    public static bool ShouldAlertProxyFailed(DateTime lastAlertUtc, DateTime now, bool running, bool paired)
    {
        if (running) return false;
        if (!paired) return false;
        return now - lastAlertUtc >= Throttle;
    }
}
