using System.Net.NetworkInformation;
using Microsoft.Win32;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Pure helpers behind the Feature #19 tamper (proxy disabled) and #20 VPN-detection checks.
/// The registry/process-facing parts are thin seams so the decisions stay unit-testable.
/// </summary>
public static class TamperChecks
{
    /// <summary>The explicit proxy the agent installs while WebFilterProxy is bound.</summary>
    public const string ExpectedProxyServer = "127.0.0.1:8877";

    /// <summary>Normalized WinINET proxy settings; ProxyEnable is null when the value is missing.</summary>
    public readonly record struct ProxySettings(bool? ProxyEnable, string? ProxyServer);

    /// <summary>A network interface reduced to the fields the VPN heuristic needs.</summary>
    public readonly record struct VpnInterfaceInfo(string Name, string Description, bool IsUp);

    /// <summary>
    /// Production reader for a single HKCU Internet Settings value (Feature #19). NOTE: reading
    /// never throws — a locked/missing key yields null, which the decision treats as "tampered
    /// when the proxy should be running" only alongside the other signals.
    /// </summary>
    public static readonly Func<string, object?> RegistryReader = name =>
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            return key?.GetValue(name);
        }
        catch (Exception)
        {
            return null;
        }
    };

    /// <summary>Reads ProxyEnable/ProxyServer through the injected reader seam (tests substitute a fake map).</summary>
    public static ProxySettings ReadProxySettings(Func<string, object?> readValue)
    {
        var enableRaw = readValue("ProxyEnable");
        // NOTE: ProxyEnable is normally a DWORD; tolerate string "1"/"0" (some tools write strings).
        bool? enable = enableRaw switch
        {
            int i => i == 1,
            string s => s.Trim() == "1",
            _ => null,
        };
        var server = readValue("ProxyServer") as string;
        return new ProxySettings(enable, server);
    }

    /// <summary>
    /// Feature #19 decision: alert only when the agent proxy is actually running (WebFilterProxy
    /// bound) while the WinINET proxy is disabled or repointed — i.e. the child turned it off.
    /// A non-running proxy means the agent itself reverted it, which is not tampering.
    /// </summary>
    public static bool ShouldAlertProxyDisabled(bool proxyRunning, ProxySettings settings) =>
        proxyRunning &&
        (settings.ProxyEnable != true ||
         !string.Equals(settings.ProxyServer?.Trim(), ExpectedProxyServer, StringComparison.OrdinalIgnoreCase));

    /// <summary>Production interface enumeration (Feature #20): name/description/up of every NIC.</summary>
    public static IReadOnlyList<VpnInterfaceInfo> ListInterfaces()
    {
        var list = new List<VpnInterfaceInfo>();
        // NOTE: enumeration is platform-integration (can throw on some NIC states); callers catch.
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            list.Add(new VpnInterfaceInfo(ni.Name, ni.Description ?? "", ni.OperationalStatus == OperationalStatus.Up));
        }
        return list;
    }

    /// <summary>True when any up interface looks like a VPN tunnel adapter.</summary>
    public static bool AnyVpnUp(IEnumerable<VpnInterfaceInfo> interfaces) =>
        interfaces.Any(i => i.IsUp && LooksLikeVpn(i.Name, i.Description));

    /// <summary>
    /// Feature #20 heuristic: VPN tunnel adapters name/describe themselves with tap/tun/wireguard.
    /// NOTE: "tun" must not match inside "tunnel" — the Teredo Tunneling pseudo-interface is not a VPN.
    /// </summary>
    public static bool LooksLikeVpn(string? name, string? description) =>
        ContainsAdapterToken(name) || ContainsAdapterToken(description);

    private static bool ContainsAdapterToken(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        var s = text.ToLowerInvariant();
        if (s.Contains("wireguard") || s.Contains("tap")) return true;
        var i = s.IndexOf("tun", StringComparison.Ordinal);
        while (i >= 0)
        {
            var after = i + 3;
            if (after >= s.Length || !char.IsLetter(s, after)) return true;
            i = s.IndexOf("tun", i + 3, StringComparison.Ordinal);
        }
        return false;
    }
}
