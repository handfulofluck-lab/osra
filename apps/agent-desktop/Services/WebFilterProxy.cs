using System.Net;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Titanium.Web.Proxy;
using Titanium.Web.Proxy.EventArguments;
using Titanium.Web.Proxy.Models;

namespace FamilyShield.Agent.Services;

/// <summary>Local explicit web proxy on 127.0.0.1:8877 that enforces the synced web-filter rules.</summary>
public sealed class WebFilterProxy : BackgroundService
{
    private const int Port = 8877;
    private const string RegistryPath = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
    private const string BlockPageHtml = "<html><body><h1>Blocked by OSRA</h1></body></html>";

    private readonly ILogger<WebFilterProxy> _log;
    private readonly LocalRuleStore _store;
    private readonly ApiClient _api;
    private readonly AgentConfig _config;
    private ProxyServer? _proxy;
    private ExplicitProxyEndPoint? _explicitEndPoint;
    private object? _previousProxyEnable;
    private object? _previousProxyServer;
    private DateTime _lastBlockAlertUtc = DateTime.MinValue;
    private DateTime _lastProxyFailedAlertUtc = DateTime.MinValue;

    /// <summary>Creates the proxy service.</summary>
    public WebFilterProxy(ILogger<WebFilterProxy> log, LocalRuleStore store, ApiClient api, AgentConfig config)
    {
        _log = log;
        _store = store;
        _api = api;
        _config = config;
    }

    /// <summary>Starts the proxy, sets the WinINET system proxy, and waits until stopped; never throws.</summary>
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            try
            {
                StartProxy();
                SetSystemProxy();
                // Feature #19: publish "proxy bound" so the RuleSyncService tamper check can tell
                // "child disabled the proxy" apart from "agent never started it".
                AgentStatus.ProxyRunning = true;
            }
            catch (Exception ex)
            {
                // NOTE: fail-open startup (QA baseline) — the worker keeps running even if the proxy
                // cannot bind or the registry is locked. Any system proxy set before the failure is
                // reverted so traffic is not black-holed by a dead 127.0.0.1:8877 endpoint, which
                // leaves the child UNFILTERED (loud error + status file record it). The spec's
                // fail-closed rule applies to the block path itself: blocked categories/domains are
                // denied — including over TLS while inspection is enabled and healthy — and HTTPS
                // cannot silently bypass filtering when FS_HTTPS_INSPECT=1 with a valid root CA.
                _log.LogError(ex, "WebFilterProxy could not start; reverting system proxy and continuing WITHOUT filtering");
                try
                {
                    RevertSystemProxy();
                }
                catch (Exception revertEx)
                {
                    _log.LogError(revertEx, "Failed to revert the system proxy after startup failure");
                }

                // Review #26: fail-open startup must also warn the parent — without it the child
                // browses unfiltered and the parent sees nothing. Throttled to one alert/hour.
                RaiseProxyFailedAlert();
            }

            AgentStatus.Write(_store.Paused, HttpsInterception.IsActive && _proxy is not null);

            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "WebFilterProxy failed unexpectedly");
        }
        finally
        {
            AgentStatus.ProxyRunning = false;
            try
            {
                StopProxy();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Failed to stop the proxy cleanly");
            }

            try
            {
                RevertSystemProxy();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Failed to revert the system proxy");
            }

            AgentStatus.Write(_store.Paused, httpsInspect: false);
        }
    }

    private void StartProxy()
    {
        // Feature #3: TLS termination only when FS_HTTPS_INSPECT=1 AND the generated root CA
        // exists/is creatable. With decryptSsl off, CONNECT tunnels are still filtered by
        // hostname in BeforeTunnelConnectRequest (#1011 criterion 4) without decrypting TLS.
        var proxy = CreateProxyServer(Port, decryptSsl: null, out var explicitEndPoint, out var decryptSsl);
        proxy.Start();
        _proxy = proxy;
        _explicitEndPoint = explicitEndPoint;
        _log.LogInformation("WebFilterProxy listening on 127.0.0.1:{Port} (httpsInspect={HttpsInspect})", Port, decryptSsl);
    }

    /// <summary>
    /// Creates and wires the <see cref="ProxyServer"/> and its <see cref="ExplicitProxyEndPoint"/>
    /// (including <c>BeforeTunnelConnectRequest</c>). Exposed as <c>internal</c> so tests can
    /// bind an ephemeral loopback port without touching the WinINET system proxy.
    /// </summary>
    internal ProxyServer CreateProxyServer(
        int port,
        bool? decryptSsl,
        out ExplicitProxyEndPoint explicitEndPoint,
        out bool effectiveDecryptSsl)
    {
        var proxy = new ProxyServer
        {
            ExceptionFunc = ex => _log.LogError(ex, "Proxy engine error"),
        };
        proxy.BeforeRequest += OnBeforeRequest;
        effectiveDecryptSsl = decryptSsl
            ?? HttpsInterception.TryConfigureDecryption(proxy, warn: message => _log.LogWarning("{Message}", message));
        explicitEndPoint = new ExplicitProxyEndPoint(IPAddress.Loopback, port, effectiveDecryptSsl);
        explicitEndPoint.BeforeTunnelConnectRequest += OnBeforeTunnelConnectRequest;
        proxy.AddEndPoint(explicitEndPoint);
        return proxy;
    }

    private void StopProxy()
    {
        var proxy = _proxy;
        var explicitEndPoint = _explicitEndPoint;
        _proxy = null;
        _explicitEndPoint = null;
        if (proxy is null) return;
        try
        {
            proxy.Stop();
        }
        finally
        {
            if (explicitEndPoint is not null)
            {
                explicitEndPoint.BeforeTunnelConnectRequest -= OnBeforeTunnelConnectRequest;
            }
            proxy.BeforeRequest -= OnBeforeRequest;
            proxy.Dispose();
        }
    }

    /// <summary>
    /// Hostname-only CONNECT gate (#1011 criterion 4): blocks forbidden domains, blocked
    /// categories, and paused non-allowed hosts before an opaque HTTPS tunnel is established,
    /// without requiring TLS decryption or a trusted root CA.
    /// </summary>
    internal Task OnBeforeTunnelConnectRequest(object sender, TunnelConnectSessionEventArgs e)
    {
        try
        {
            var request = e.HttpClient.Request;
            var host = ConnectHostGate.NormalizeConnectHost(request.RequestUri?.Host, request.Host);
            if (host is null) return Task.CompletedTask;

            var decision = ConnectHostGate.Evaluate(host, e.DecryptSsl, _store, out var category);
            var connectUrl = $"https://{host}/";

            switch (decision)
            {
                case ConnectDecision.BlockPaused:
                    _log.LogInformation("Internet paused; denied CONNECT tunnel to {Host}", host);
                    _store.LogUrl(host, connectUrl, null, true);
                    e.DenyConnect = true;
                    break;
                case ConnectDecision.BlockRule:
                    _log.LogInformation("Blocked CONNECT tunnel to {Host} (category={Category})", host, category ?? "custom");
                    _store.LogUrl(host, connectUrl, category, true);
                    RaiseBlockAlert(host, connectUrl, category);
                    e.DenyConnect = true;
                    break;
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Error while handling a CONNECT tunnel request");
        }

        return Task.CompletedTask;
    }

    private async Task OnBeforeRequest(object sender, SessionEventArgs e)
    {
        try
        {
            var request = e.HttpClient.Request;
            var host = request.RequestUri?.Host ?? request.Host;
            var url = request.RequestUri?.AbsoluteUri ?? request.Url;
            if (string.IsNullOrWhiteSpace(host)) return;

            // Feature #11: while paused, sinkhole everything except the rule set's allowedDomains.
            // Plain HTTP and (with inspection on) decrypted HTTPS receive the HTML block page here;
            // opaque CONNECT tunnels when decryptSsl is off are denied at CONNECT in
            // OnBeforeTunnelConnectRequest (#1011 criterion 4). Browsers are not killed; the block
            // page / CONNECT refusal is the enforcement (ProcessMonitor is untouched).
            if (_store.Paused && PauseGate.ShouldServeBlockPageWhenPaused(host, _store.Current?.AllowedDomains))
            {
                _log.LogInformation("Internet paused; sinkholed request to {Host}", host);
                _store.LogUrl(host, url, null, true);
                e.Ok(BlockPageHtml, new Dictionary<string, HttpHeader>
                {
                    ["Content-Type"] = new HttpHeader("Content-Type", "text/html"),
                });
                return;
            }

            var category = _store.LookupCategory(host);
            var blocked = _store.ShouldBlock(host, url);

            if (!blocked)
            {
                if (SafeSearch.IsYouTubeHost(host))
                {
                    var ytMode = _store.Current?.YoutubeRestrictedMode ?? (_store.Current?.SafeSearchEnforced == true ? "strict" : "off");
                    var ytHeader = SafeSearch.GetYouTubeRestrictHeaderValue(ytMode);
                    if (ytHeader is not null)
                    {
                        request.Headers.AddHeader(new HttpHeader("YouTube-Restrict", ytHeader));
                        if (_store.Current?.SafeSearchEnforced == true && SafeSearch.TryRewrite(host, url, out var rewritten))
                        {
                            e.Redirect(rewritten);
                        }
                    }
                }
                else if (_store.Current?.SafeSearchEnforced == true)
                {
                    if (SafeSearch.IsGoogleHost(host))
                    {
                        request.Headers.AddHeader(new HttpHeader("X-SafeSearch", "true"));
                    }

                    if (SafeSearch.TryRewrite(host, url, out var rewritten))
                    {
                        e.Redirect(rewritten);
                    }
                }
            }

            if (SafeSearch.ExtractSearchQuery(host, url, out var engine, out var query) && !string.IsNullOrWhiteSpace(query))
            {
                _log.LogInformation("Search query on {Engine}: {Query}", engine, query);
                category ??= $"search:{engine}";
            }

            _store.LogUrl(host, url, category, blocked);

            if (blocked)
            {
                _log.LogInformation("Blocked request to {Host}{Path}", host, request.RequestUri?.PathAndQuery);
                RaiseBlockAlert(host, url, category);
                // NOTE: spec asks for a 200 text/html response on the block page.
                e.Ok(BlockPageHtml, new Dictionary<string, HttpHeader>
                {
                    ["Content-Type"] = new HttpHeader("Content-Type", "text/html"),
                });
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Error while handling a proxied request");
        }

        await Task.CompletedTask;
    }

    /// <summary>Raises a throttled web_threat alert so blocked sites appear in the parent app.</summary>
    private void RaiseBlockAlert(string host, string url, string? category)
    {
        if (string.IsNullOrEmpty(_config.ChildId) || string.IsNullOrEmpty(_config.DeviceId)) return;
        // Throttle to one alert per minute so a reload loop cannot spam the parent.
        if ((DateTime.UtcNow - _lastBlockAlertUtc) < TimeSpan.FromMinutes(1)) return;
        _lastBlockAlertUtc = DateTime.UtcNow;
        _ = _api.PostAlert(new AlertDto
        {
            ChildId = _config.ChildId,
            DeviceId = _config.DeviceId,
            Severity = "warning",
            Category = "web_threat",
            Title = $"Blocked website: {host}",
            Body = category is null ? url : $"{url} (category: {category})",
            Metadata = new Dictionary<string, object> { ["host"] = host, ["url"] = url, ["category"] = category ?? "custom" },
        });
    }

    /// <summary>Raises a throttled tamper alert when the proxy fails to start (review #26).</summary>
    private void RaiseProxyFailedAlert()
    {
        // Mirror ProcessMonitor/RuleSyncService: never alert before pairing (no parent to notify).
        var paired = !string.IsNullOrEmpty(_config.ChildId) && !string.IsNullOrEmpty(_config.DeviceId);
        if (!ProxyStartupAlert.ShouldAlertProxyFailed(_lastProxyFailedAlertUtc, DateTime.UtcNow, AgentStatus.ProxyRunning, paired)) return;
        _lastProxyFailedAlertUtc = DateTime.UtcNow;
        // PostAlert swallows network errors internally; fire-and-forget like RaiseBlockAlert.
        _ = _api.PostAlert(new AlertDto
        {
            ChildId = _config.ChildId,
            DeviceId = _config.DeviceId,
            Severity = "warning",
            Category = "tamper",
            Title = "Web filter failed to start",
            Body = "The OSRA proxy could not start on this PC; the child may be browsing unfiltered. Check the agent console.",
            Metadata = new Dictionary<string, object> { ["type"] = "proxy_failed" },
        });
    }

    // NOTE: with HTTPS inspection off (default), HTTPS requests arrive as CONNECT tunnels and
    // are filtered by hostname in OnBeforeTunnelConnectRequest (#1011 criterion 4) without
    // decrypting TLS; URL path/SafeSearch rewriting requires FS_HTTPS_INSPECT=1 plus a trusted
    // root certificate. The SafeSearch rewrite itself lives in the pure SafeSearch helper.

    private void SetSystemProxy()
    {
        var env = Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY") ??
                  Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY", EnvironmentVariableTarget.User);
        if (!_config.SetSystemProxy || string.Equals(env, "0", StringComparison.OrdinalIgnoreCase) || string.Equals(env, "false", StringComparison.OrdinalIgnoreCase))
        {
            _log.LogInformation("WinINET system proxy registration disabled (SetSystemProxy=false / FS_SET_SYSTEM_PROXY=0); running proxy on 127.0.0.1:{Port} without modifying system proxy", Port);
            return;
        }

        using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
        if (key is null) throw new InvalidOperationException("Internet Settings registry key not found");
        _previousProxyEnable = key.GetValue("ProxyEnable");
        _previousProxyServer = key.GetValue("ProxyServer");
        key.SetValue("ProxyEnable", 1);
        key.SetValue("ProxyServer", $"127.0.0.1:{Port}");
        RefreshWininet();
        _log.LogInformation("WinINET system proxy set to 127.0.0.1:{Port}", Port);
    }

    /// <summary>Re-applies the WinINET system proxy if tampered (WIN-06 self-healing).</summary>
    public static void EnsureSystemProxy(int port = 8877)
    {
        var env = Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY") ??
                  Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY", EnvironmentVariableTarget.User);
        if (string.Equals(env, "0", StringComparison.OrdinalIgnoreCase) || string.Equals(env, "false", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
            if (key is null) return;
            key.SetValue("ProxyEnable", 1);
            key.SetValue("ProxyServer", $"127.0.0.1:{port}");
            RefreshWininet();
        }
        catch (Exception)
        {
            // best-effort
        }
    }

    /// <summary>
    /// Resets the WinINET system proxy if currently pointed to 127.0.0.1:{port}.
    /// Cleans both main registry keys and legacy Connections blobs to prevent orphaned proxies.
    /// </summary>
    public static void ResetSystemProxyIfSet(int port = 8877)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
            if (key is null) return;
            var server = key.GetValue("ProxyServer") as string;
            var enable = key.GetValue("ProxyEnable");
            if (string.Equals(server?.Trim(), $"127.0.0.1:{port}", StringComparison.OrdinalIgnoreCase) ||
                enable is 1 or "1")
            {
                key.SetValue("ProxyEnable", 0);
                key.DeleteValue("ProxyServer", throwOnMissingValue: false);

                try
                {
                    using var connKey = Registry.CurrentUser.OpenSubKey(RegistryPath + @"\Connections", writable: true);
                    if (connKey != null)
                    {
                        connKey.DeleteValue("DefaultConnectionSettings", throwOnMissingValue: false);
                        connKey.DeleteValue("SavedLegacySettings", throwOnMissingValue: false);
                    }
                }
                catch { }

                RefreshWininet();
            }
        }
        catch { }
    }

    private void RevertSystemProxy()
    {
        if (!_config.SetSystemProxy) return;

        using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
        if (key is null) return;
        RestoreValue(key, "ProxyEnable", _previousProxyEnable);
        RestoreValue(key, "ProxyServer", _previousProxyServer);

        try
        {
            using var connKey = Registry.CurrentUser.OpenSubKey(RegistryPath + @"\Connections", writable: true);
            if (connKey != null)
            {
                connKey.DeleteValue("DefaultConnectionSettings", throwOnMissingValue: false);
                connKey.DeleteValue("SavedLegacySettings", throwOnMissingValue: false);
            }
        }
        catch
        {
            // best-effort
        }

        RefreshWininet();
    }

    private static void RestoreValue(RegistryKey key, string name, object? previous)
    {
        if (previous is null)
            key.DeleteValue(name, throwOnMissingValue: false);
        else
            key.SetValue(name, previous);
    }

    private static void RefreshWininet() =>
        InternetSetOption(IntPtr.Zero, 39 /* INTERNET_OPTION_SETTINGS_CHANGED */, IntPtr.Zero, 0);

    [DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
