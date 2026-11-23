using System.Net;
using System.Net.Sockets;
using System.Text;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit and real-loopback CONNECT tests for <see cref="ConnectHostGate"/> and
/// <see cref="WebFilterProxy.OnBeforeTunnelConnectRequest"/> (#1011 criterion 4).
/// </summary>
public sealed class ConnectHostGateTests : IDisposable
{
    private readonly LocalRuleStore _store;
    private readonly string _dbPath;
    private readonly string _statusPath;

    public ConnectHostGateTests()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-connect-tests", Guid.NewGuid().ToString("N"));
        _dbPath = Path.Combine(dir, "agent.db");
        _statusPath = Path.Combine(dir, "status.json");
        _store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance, _dbPath, _statusPath);
        _store.Initialize();
        _store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto
            {
                BlockedCategories = new List<string> { "gambling" },
                AllowedDomains = new List<string> { "school.edu" },
                BlockedDomains = new List<string> { "whatsapp.com", "youtube.com" },
            },
        });
    }

    [Fact]
    public void NormalizeConnectHostStripsPortBracketsAndTrailingDot()
    {
        // Mutant: omitting ":port" stripping leaves "web.whatsapp.com:443", which never matches "whatsapp.com".
        Assert.Equal("web.whatsapp.com", ConnectHostGate.NormalizeConnectHost("web.whatsapp.com", "web.whatsapp.com:443"));
        Assert.Equal("web.whatsapp.com", ConnectHostGate.NormalizeConnectHost(null, "web.whatsapp.com:443"));
        Assert.Equal("WEB.WHATSAPP.COM", ConnectHostGate.NormalizeConnectHost("  WEB.WHATSAPP.COM.:443  ", null));
        Assert.Equal("::1", ConnectHostGate.NormalizeConnectHost(null, "[::1]:443"));
        Assert.Null(ConnectHostGate.NormalizeConnectHost("", "   "));
    }

    [Fact]
    public void BlocksExactAndSubdomainWhenHttpsInspectionIsOff()
    {
        // Mutant: returning Allow when decryptSsl == false leaves HTTPS tunnels unfiltered.
        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("whatsapp.com", decryptSsl: false, _store, out var cat1));
        Assert.Equal("custom", cat1);

        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("web.whatsapp.com", decryptSsl: false, _store, out var cat2));
        Assert.Equal("custom", cat2);

        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("m.youtube.com", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("WEB.WHATSAPP.COM.", decryptSsl: false, _store, out _));
    }

    [Fact]
    public void LookalikeDomainsAreNotBlockedAtConnect()
    {
        // Mutant: EndsWith(domain) instead of EndsWith("." + domain) would falsely block "notwhatsapp.com".
        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("notwhatsapp.com", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("whatsapp.com.evil.org", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("myyoutube.com", decryptSsl: false, _store, out _));
    }

    [Fact]
    public void UnblockingDomainViaRuleSyncAllowsConnectAgain()
    {
        // Mutant: failing to clear 'custom' blocked domains on Sync would keep blocking after unblock.
        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("web.whatsapp.com", decryptSsl: false, _store, out _));

        _store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto
            {
                BlockedCategories = new List<string>(),
                AllowedDomains = new List<string> { "school.edu" },
                BlockedDomains = new List<string> { "youtube.com" },
            },
        });

        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("web.whatsapp.com", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("m.youtube.com", decryptSsl: false, _store, out _));
    }

    [Fact]
    public void AllowedSubdomainOverridesBlockedParentAtConnect()
    {
        // Mutant: checking BlockedDomains before AllowedDomains would block the allowed subdomain.
        _store.Sync(new RuleSetDto
        {
            WebFilter = new WebFilterRuleDto
            {
                AllowedDomains = new List<string> { "web.whatsapp.com" },
                BlockedDomains = new List<string> { "whatsapp.com" },
            },
        });

        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("web.whatsapp.com", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("api.whatsapp.com", decryptSsl: false, _store, out _));
    }

    [Fact]
    public void BlockedCategoryIsDeniedAtConnectWithCategoryName()
    {
        // Mutant: checking only BlockedDomains (skipping LookupCategory/ShouldBlock) misses category blocks over HTTPS.
        Assert.Equal(ConnectDecision.BlockRule, ConnectHostGate.Evaluate("bet365.com", decryptSsl: false, _store, out var category));
        Assert.Equal("gambling", category);
    }

    [Fact]
    public void PausedInternetDeniesNonAllowedConnectAndAllowsAllowlistedHost()
    {
        // Mutant: skipping PauseGate in CONNECT leaves HTTPS open while internet is paused.
        _store.SetPaused(true);

        Assert.Equal(ConnectDecision.BlockPaused, ConnectHostGate.Evaluate("wikipedia.org", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("school.edu", decryptSsl: false, _store, out _));
        Assert.Equal(ConnectDecision.Allow, ConnectHostGate.Evaluate("portal.school.edu", decryptSsl: false, _store, out _));
    }

    [Fact]
    public void DefersToBeforeRequestWhenHttpsDecryptionIsActive()
    {
        // Mutant: denying at CONNECT even when decryptSsl == true would prevent the Feature #3 HTML block page.
        Assert.Equal(
            ConnectDecision.DeferToDecryptedRequest,
            ConnectHostGate.Evaluate("web.whatsapp.com", decryptSsl: true, _store, out _));
    }

    [Fact]
    public async Task ProxyDeniesBlockedConnectWithoutHttpsInspectionAndLogsUrl()
    {
        // Mutant: removing explicitEndPoint.BeforeTunnelConnectRequest += OnBeforeTunnelConnectRequest
        // in WebFilterProxy.CreateProxyServer leaves CONNECT tunnels unfiltered when decryptSsl == false.
        var config = new AgentConfig { SetSystemProxy = false };
        using var http = new HttpClient();
        var api = new ApiClient(http, config);
        var service = new WebFilterProxy(NullLogger<WebFilterProxy>.Instance, _store, api, config);

        using var proxy = service.CreateProxyServer(0, decryptSsl: false, out var ep, out var effectiveDecryptSsl);
        Assert.False(effectiveDecryptSsl);
        proxy.Start();
        try
        {
            var statusLine = await SendConnectAsync(ep.Port, "web.whatsapp.com", 443);
            Assert.Contains("403", statusLine, StringComparison.Ordinal);

            var batch = _store.GetUnuploadedTelemetry();
            Assert.Contains(batch.Urls, u => u.Host == "web.whatsapp.com" && u.Blocked);
        }
        finally
        {
            proxy.Stop();
            ep.BeforeTunnelConnectRequest -= service.OnBeforeTunnelConnectRequest;
        }
    }

    [Fact]
    public async Task ProxyAllowsUnblockedConnectBlocksWhenSyncedAndAllowsAgainWhenUnblocked()
    {
        // Mutant: denying all CONNECT requests unconditionally (or failing to re-read _store.Current)
        // breaks either the initial 200 or the post-unblock 200.
        var config = new AgentConfig { SetSystemProxy = false };
        using var http = new HttpClient();
        var api = new ApiClient(http, config);
        var service = new WebFilterProxy(NullLogger<WebFilterProxy>.Instance, _store, api, config);

        using var upstream = new TcpListener(IPAddress.Loopback, 0);
        upstream.Start();
        var upstreamPort = ((IPEndPoint)upstream.LocalEndpoint).Port;
        using var acceptCts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var acceptLoop = Task.Run(async () =>
        {
            while (!acceptCts.IsCancellationRequested)
            {
                try
                {
                    using var client = await upstream.AcceptTcpClientAsync(acceptCts.Token);
                    await Task.Delay(50, acceptCts.Token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
            }
        });

        using var proxy = service.CreateProxyServer(0, decryptSsl: false, out var ep, out _);
        proxy.Start();
        try
        {
            // 1. Not blocked -> CONNECT succeeds (200)
            var allowedBefore = await SendConnectAsync(ep.Port, "127.0.0.1", upstreamPort);
            Assert.Contains("200", allowedBefore, StringComparison.Ordinal);

            // 2. Blocked via rule sync -> CONNECT denied (403)
            _store.Sync(new RuleSetDto
            {
                WebFilter = new WebFilterRuleDto
                {
                    BlockedDomains = new List<string> { "127.0.0.1" },
                },
            });
            var blocked = await SendConnectAsync(ep.Port, "127.0.0.1", upstreamPort);
            Assert.Contains("403", blocked, StringComparison.Ordinal);

            // 3. Unblocked via rule sync -> CONNECT succeeds again (200)
            _store.Sync(new RuleSetDto
            {
                WebFilter = new WebFilterRuleDto
                {
                    BlockedDomains = new List<string>(),
                },
            });
            var allowedAfter = await SendConnectAsync(ep.Port, "127.0.0.1", upstreamPort);
            Assert.Contains("200", allowedAfter, StringComparison.Ordinal);

            // 4. Paused -> CONNECT denied (403) unless in AllowedDomains (200)
            _store.SetPaused(true);
            var pausedBlocked = await SendConnectAsync(ep.Port, "127.0.0.1", upstreamPort);
            Assert.Contains("403", pausedBlocked, StringComparison.Ordinal);

            _store.Sync(new RuleSetDto
            {
                WebFilter = new WebFilterRuleDto
                {
                    AllowedDomains = new List<string> { "127.0.0.1" },
                },
            });
            var pausedAllowed = await SendConnectAsync(ep.Port, "127.0.0.1", upstreamPort);
            Assert.Contains("200", pausedAllowed, StringComparison.Ordinal);
        }
        finally
        {
            acceptCts.Cancel();
            upstream.Stop();
            proxy.Stop();
            ep.BeforeTunnelConnectRequest -= service.OnBeforeTunnelConnectRequest;
            try { await acceptLoop; } catch (Exception) { }
        }
    }

    private static async Task<string> SendConnectAsync(int proxyPort, string host, int targetPort)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, proxyPort);
        using var stream = client.GetStream();
        stream.ReadTimeout = 5000;
        stream.WriteTimeout = 5000;

        var req = $"CONNECT {host}:{targetPort} HTTP/1.1\r\nHost: {host}:{targetPort}\r\nProxy-Connection: Keep-Alive\r\n\r\n";
        var bytes = Encoding.ASCII.GetBytes(req);
        await stream.WriteAsync(bytes);
        await stream.FlushAsync();

        var buf = new byte[1024];
        var read = await stream.ReadAsync(buf);
        var response = Encoding.ASCII.GetString(buf, 0, read);
        var firstLineEnd = response.IndexOf("\r\n", StringComparison.Ordinal);
        return firstLineEnd >= 0 ? response[..firstLineEnd] : response;
    }

    public void Dispose()
    {
        _store.Dispose();
        try
        {
            var dir = Path.GetDirectoryName(_dbPath);
            if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch (Exception)
        {
            // temp cleanup is best-effort
        }
    }
}
