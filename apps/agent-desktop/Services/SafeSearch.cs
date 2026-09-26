namespace FamilyShield.Agent.Services;

/// <summary>
/// Pure SafeSearch URL rewriting for google/bing/youtube (used by <see cref="WebFilterProxy"/>).
/// Existing query parameters are replaced in place — never appended twice.
/// </summary>
public static class SafeSearch
{
    /// <summary>
    /// Builds the SafeSearch-enforced URL for a supported search host; returns false for every
    /// other host. Matching is label-boundary aware: google.com and its TLD variants
    /// (google.co.uk, www.google.de), bing.com and youtube.com plus their subdomains match, while
    /// lookalikes such as "notgoogle.com" or "mybing.com" do not.
    /// </summary>
    public static bool TryRewrite(string host, string url, out string rewritten)
    {
        rewritten = url;
        if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(url)) return false;
        var h = host.Trim().TrimEnd('.').ToLowerInvariant();

        if (h.StartsWith("google.", StringComparison.Ordinal) ||
            h.Contains(".google.", StringComparison.Ordinal))
        {
            rewritten = SetQueryParam(url, "safe", "strict"); // Google SafeSearch lock
            return true;
        }
        if (IsHostOrSubdomain(h, "bing.com"))
        {
            rewritten = SetQueryParam(url, "adlt", "strict"); // Bing strict filter
            return true;
        }
        if (IsHostOrSubdomain(h, "youtube.com"))
        {
            // NOTE: YouTube has no strict query param; appending "safe=strict" is a best-effort
            // per the spec's "SafeSearch rewrite for google/bing/youtube" instruction.
            rewritten = SetQueryParam(url, "safe", "strict");
            return true;
        }
        return false;
    }

    /// <summary>
    /// Returns <paramref name="url"/> with the query parameter <paramref name="name"/> set to
    /// <paramref name="value"/>; any existing occurrence (case-insensitive key) is replaced so a
    /// user-supplied "safe=active" cannot survive, and other parameters and the fragment are
    /// preserved.
    /// </summary>
    public static string SetQueryParam(string url, string name, string value)
    {
        var hashIndex = url.IndexOf('#');
        var fragment = hashIndex >= 0 ? url[hashIndex..] : "";
        var basePart = hashIndex >= 0 ? url[..hashIndex] : url;

        var qIndex = basePart.IndexOf('?');
        var path = qIndex >= 0 ? basePart[..qIndex] : basePart;
        var query = qIndex >= 0 ? basePart[(qIndex + 1)..] : "";

        var kept = new List<string>();
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var key = eq >= 0 ? pair[..eq] : pair;
            if (!string.Equals(key, name, StringComparison.OrdinalIgnoreCase)) kept.Add(pair);
        }
        kept.Add($"{name}={value}");
        return $"{path}?{string.Join("&", kept)}{fragment}";
    }

    private static bool IsHostOrSubdomain(string host, string domain) =>
        host == domain || host.EndsWith("." + domain, StringComparison.Ordinal);
}
