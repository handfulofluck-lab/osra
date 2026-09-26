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
        var proxy = new ProxyServer
        {
            ExceptionFunc = ex => _log.LogError(ex, "Proxy engine error"),
        };
        proxy.BeforeRequest += OnBeforeRequest;
        // Feature #3: TLS termination only when FS_HTTPS_INSPECT=1 AND the generated root CA
        // exists/is creatable. With decryptSsl off, HTTPS flows are tunnelled untouched and only
        // plain HTTP is filtered/logged (previous behavior).
        var decryptSsl = HttpsInterception.TryConfigureDecryption(proxy);
        proxy.AddEndPoint(new ExplicitProxyEndPoint(IPAddress.Loopback, Port, decryptSsl));
        proxy.Start();
        _proxy = proxy;
        _log.LogInformation("WebFilterProxy listening on 127.0.0.1:{Port} (httpsInspect={HttpsInspect})", Port, decryptSsl);
    }

    private void StopProxy()
    {
        var proxy = _proxy;
        _proxy = null;
        if (proxy is null) return;
        try
        {
            proxy.Stop();
        }
        finally
        {
            proxy.BeforeRequest -= OnBeforeRequest;
            proxy.Dispose();
        }
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
            // NOTE: this gate sees plain HTTP and (with inspection on) decrypted HTTPS; opaque
            // CONNECT tunnels still pass while decryptSsl is off — pausing is fail-open for
            // HTTPS unless FS_HTTPS_INSPECT=1. Browsers are not killed; the block page is the
            // enforcement (ProcessMonitor is untouched).
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

            if (!blocked && _store.Current?.SafeSearchEnforced == true &&
                SafeSearch.TryRewrite(host, url, out var rewritten))
            {
                e.Redirect(rewritten);
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

    // NOTE: HTTPS requests are only visible as CONNECT tunnels unless the agent root CA is trusted,
    // so blocking/decryption applies to plain HTTP requests; domain-level HTTPS blocking would need
    // BeforeTunnelConnectRequest plus a trusted root certificate. The SafeSearch rewrite itself
    // lives in the pure SafeSearch helper (query params are replaced, never duplicated).

    private void SetSystemProxy()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
        if (key is null) throw new InvalidOperationException("Internet Settings registry key not found");
        _previousProxyEnable = key.GetValue("ProxyEnable");
        _previousProxyServer = key.GetValue("ProxyServer");
        key.SetValue("ProxyEnable", 1);
        key.SetValue("ProxyServer", $"127.0.0.1:{Port}");
        RefreshWininet();
        _log.LogInformation("WinINET system proxy set to 127.0.0.1:{Port}", Port);
    }

    private void RevertSystemProxy()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
        if (key is null) return;
        RestoreValue(key, "ProxyEnable", _previousProxyEnable);
        RestoreValue(key, "ProxyServer", _previousProxyServer);
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
