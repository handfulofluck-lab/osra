namespace FamilyShield.Agent.Services;

/// <summary>
/// Feature #11 pause gate: while the internet is paused the proxy sinkholes every request to the
/// block page EXCEPT hosts in the synced rule set's allowedDomains. The emergency set is empty —
/// no domain (google.com included) is hard-coded as emergency; the OS emergency dialer is
/// unaffected because it does not route through the browser/system proxy at all (NOTE).
/// </summary>
public static class PauseGate
{
    /// <summary>
    /// True when a request to <paramref name="host"/> must get the block page while paused:
    /// every host is blocked unless it matches an allowed domain (exact or subdomain,
    /// label-boundary aware). Empty/whitespace hosts are not blocked here.
    /// </summary>
    public static bool ShouldServeBlockPageWhenPaused(string? host, IEnumerable<string>? allowedDomains)
    {
        if (string.IsNullOrWhiteSpace(host)) return false;
        if (allowedDomains is null) return true;
        return !allowedDomains.Any(d => DomainMatches(host, d));
    }

    private static bool DomainMatches(string host, string domain)
    {
        var h = Normalize(host);
        var d = Normalize(domain);
        return d.Length > 0 && (h == d || h.EndsWith("." + d, StringComparison.Ordinal));
    }

    private static string Normalize(string host) => host.Trim().TrimEnd('.').ToLowerInvariant();
}
