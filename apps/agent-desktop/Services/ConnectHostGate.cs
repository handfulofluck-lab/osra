namespace FamilyShield.Agent.Services;

/// <summary>Decision returned by <see cref="ConnectHostGate"/> for an HTTP CONNECT tunnel.</summary>
public enum ConnectDecision
{
    /// <summary>Tunnel may proceed untouched.</summary>
    Allow,

    /// <summary>TLS decryption is active; let <c>BeforeRequest</c> handle the decrypted request and serve the HTML block page.</summary>
    DeferToDecryptedRequest,

    /// <summary>Deny the CONNECT tunnel because the internet is paused and the host is not in <c>allowedDomains</c>.</summary>
    BlockPaused,

    /// <summary>Deny the CONNECT tunnel because the host matches a blocked domain or blocked category.</summary>
    BlockRule,
}

/// <summary>
/// Hostname-only CONNECT gate for <see cref="WebFilterProxy"/> (#1011 criterion 4):
/// inspects the CONNECT authority hostname without decrypting TLS so blocked domains,
/// blocked categories, and internet-pause rules still enforce when HTTPS inspection is off.
/// </summary>
public static class ConnectHostGate
{
    /// <summary>
    /// Extracts and normalizes a bare hostname (no port, no brackets, no trailing dot) from
    /// a CONNECT request's URI host and/or Host header. Returns null when neither contains a host.
    /// </summary>
    public static string? NormalizeConnectHost(string? requestUriHost, string? hostHeader)
    {
        var raw = !string.IsNullOrWhiteSpace(requestUriHost) ? requestUriHost : hostHeader;
        if (string.IsNullOrWhiteSpace(raw)) return null;

        var trimmed = raw.Trim();

        // Bracketed IPv6 authority: "[::1]:443" or "[::1]"
        if (trimmed.StartsWith('['))
        {
            var close = trimmed.IndexOf(']');
            if (close > 1)
            {
                trimmed = trimmed[1..close];
            }
        }
        else
        {
            // Strip ":port" when there is a single colon (host:443). Leave bare IPv6 intact.
            var firstColon = trimmed.IndexOf(':');
            if (firstColon >= 0 && firstColon == trimmed.LastIndexOf(':'))
            {
                trimmed = trimmed[..firstColon];
            }
        }

        trimmed = trimmed.Trim().TrimEnd('.');
        return trimmed.Length == 0 ? null : trimmed;
    }

    /// <summary>
    /// Evaluates whether an incoming CONNECT tunnel to <paramref name="host"/> should be denied.
    /// When <paramref name="decryptSsl"/> is true, defers to <c>BeforeRequest</c> so decrypted
    /// HTTPS requests continue to receive the HTML block page.
    /// </summary>
    public static ConnectDecision Evaluate(
        string? host,
        bool decryptSsl,
        LocalRuleStore store,
        out string? category)
    {
        category = null;
        if (string.IsNullOrWhiteSpace(host)) return ConnectDecision.Allow;
        if (decryptSsl) return ConnectDecision.DeferToDecryptedRequest;

        if (store.Paused && PauseGate.ShouldServeBlockPageWhenPaused(host, store.Current?.AllowedDomains))
        {
            return ConnectDecision.BlockPaused;
        }

        var connectUrl = $"https://{host}/";
        if (store.ShouldBlock(host, connectUrl))
        {
            category = store.LookupCategory(host);
            return ConnectDecision.BlockRule;
        }

        return ConnectDecision.Allow;
    }
}
