using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Feature #19 (tamper: proxy disabled) and Feature #20 (VPN detection) tests: the pure
/// proxy-settings reader/decision, the LooksLikeVpn heuristic, and the RuleSyncService
/// wiring (throttled alerts via injected seams; no registry or NIC table is touched).
/// </summary>
public sealed class TamperVpnTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"));
    private readonly List<LocalRuleStore> _stores = [];

    public void Dispose()
    {
        foreach (var store in _stores) store.Dispose();
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception)
        {
            // temp cleanup is best-effort
        }
    }

    private LocalRuleStore CreateStore()
    {
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(_dir, "agent.db"), Path.Combine(_dir, "status.json"));
        _stores.Add(store);
        return store;
    }

    // ---- Feature #19: proxy-settings read abstraction ----

    [Fact]
    public void ReadProxySettingsNormalizesDwordValues()
    {
        var values = new Dictionary<string, object?> { ["ProxyEnable"] = 1, ["ProxyServer"] = "127.0.0.1:8877" };
        var settings = TamperChecks.ReadProxySettings(values.GetValueOrDefault);
        Assert.True(settings.ProxyEnable);
        Assert.Equal("127.0.0.1:8877", settings.ProxyServer);
    }

    [Fact]
    public void ReadProxySettingsToleratesStringProxyEnable()
    {
        var values = new Dictionary<string, object?> { ["ProxyEnable"] = "0", ["ProxyServer"] = "127.0.0.1:9999" };
        var settings = TamperChecks.ReadProxySettings(values.GetValueOrDefault);
        Assert.False(settings.ProxyEnable);
        Assert.Equal("127.0.0.1:9999", settings.ProxyServer);
    }

    [Fact]
    public void ReadProxySettingsLeavesMissingValuesNull()
    {
        var settings = TamperChecks.ReadProxySettings(_ => null);
        Assert.Null(settings.ProxyEnable);
        Assert.Null(settings.ProxyServer);
    }

    // ---- Feature #19: tamper decision ----

    [Fact]
    public void ProxyDisabledWhileRunningIsTampering()
    {
        var settings = new TamperChecks.ProxySettings(false, "127.0.0.1:8877");
        Assert.True(TamperChecks.ShouldAlertProxyDisabled(proxyRunning: true, settings));
    }

    [Fact]
    public void ProxyRepointedWhileRunningIsTampering()
    {
        var settings = new TamperChecks.ProxySettings(true, "192.168.1.1:8080");
        Assert.True(TamperChecks.ShouldAlertProxyDisabled(proxyRunning: true, settings));
    }

    [Fact]
    public void CorrectProxyWhileRunningIsNotTampering()
    {
        var settings = new TamperChecks.ProxySettings(true, "127.0.0.1:8877");
        Assert.False(TamperChecks.ShouldAlertProxyDisabled(proxyRunning: true, settings));
    }

    [Fact]
    public void ProxyComparisonIgnoresCaseAndSurroundingWhitespace()
    {
        var settings = new TamperChecks.ProxySettings(true, "  127.0.0.1:8877 ");
        Assert.False(TamperChecks.ShouldAlertProxyDisabled(proxyRunning: true, settings));
    }

    [Fact]
    public void MissingRegistryValuesWhileRunningAreTampering()
    {
        var settings = new TamperChecks.ProxySettings(null, null);
        Assert.True(TamperChecks.ShouldAlertProxyDisabled(proxyRunning: true, settings));
    }

    [Fact]
    public void DisabledProxyWhileNotRunningIsNotTampering()
    {
        // The agent itself reverts the proxy on shutdown/startup failure — never an alert.
        var settings = new TamperChecks.ProxySettings(false, null);
        Assert.False(TamperChecks.ShouldAlertProxyDisabled(proxyRunning: false, settings));
    }

    // ---- Feature #20: VPN heuristic ----

    [Theory]
    [InlineData("TAP-Windows Adapter V9", "TAP-Windows Adapter V9")]
    [InlineData("Ethernet", "WireGuard Tunnel")]
    [InlineData("tun0", "")]
    [InlineData("wintun", "Wintun Userspace Tunnel")]
    [InlineData("surfshark", "Surfshark WireGuard")]
    public void LooksLikeVpnMatchesTunnelAdapters(string? name, string? description)
    {
        Assert.True(TamperChecks.LooksLikeVpn(name, description));
    }

    [Theory]
    [InlineData("Ethernet", "Intel(R) Ethernet Controller")]
    [InlineData("Wi-Fi", "802.11n USB Wireless LAN Card")]
    [InlineData("Local Area Connection* 12", "Microsoft Wi-Fi Direct Virtual Adapter")]
    [InlineData("Teredo Tunneling Pseudo-Interface", "Teredo Tunneling Pseudo-Interface")]
    [InlineData("", "")]
    [InlineData(null, null)]
    public void LooksLikeVpnIgnoresOrdinaryAndTeredoAdapters(string? name, string? description)
    {
        Assert.False(TamperChecks.LooksLikeVpn(name, description));
    }

    [Fact]
    public void AnyVpnUpOnlyCountsUpInterfaces()
    {
        var upVpn = new TamperChecks.VpnInterfaceInfo("tun0", "tun", IsUp: true);
        var downVpn = new TamperChecks.VpnInterfaceInfo("tap1", "tap", IsUp: false);
        var upEthernet = new TamperChecks.VpnInterfaceInfo("Ethernet", "Intel Ethernet", IsUp: true);

        Assert.True(TamperChecks.AnyVpnUp([upEthernet, upVpn]));
        Assert.False(TamperChecks.AnyVpnUp([upEthernet, downVpn]));
        Assert.False(TamperChecks.AnyVpnUp([]));
    }

    // ---- RuleSyncService wiring: throttled alerts through the injected seams ----

    [Fact]
    public void CheckTamperAndVpnRaisesTheContractTamperAlert()
    {
        var (api, sync) = CreateSync(
            proxyRunning: true,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 0, ["ProxyServer"] = "127.0.0.1:8877" },
            interfaces: [new TamperChecks.VpnInterfaceInfo("Ethernet", "Intel Ethernet", IsUp: true)]);

        sync.CheckTamperAndVpn();

        var alert = Assert.Single(api.Alerts);
        Assert.Equal("tamper", alert.Category);
        Assert.Equal("critical", alert.Severity);
        Assert.Equal("Web filter was bypassed", alert.Title);
        Assert.Equal("The OSRA proxy was disabled in Windows settings", alert.Body);
        Assert.Equal("proxy_disabled", alert.Metadata?["type"]);
        Assert.Equal("child-1", alert.ChildId);
        Assert.Equal("device-1", alert.DeviceId);
    }

    [Fact]
    public void CheckTamperAndVpnInvokesEnsureProxyEnforced()
    {
        var (api, sync) = CreateSync(
            proxyRunning: true,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 0, ["ProxyServer"] = "127.0.0.1:8877" },
            interfaces: [new TamperChecks.VpnInterfaceInfo("Ethernet", "Intel Ethernet", IsUp: true)]);

        var enforced = false;
        sync.EnsureProxyEnforced = () => enforced = true;

        sync.CheckTamperAndVpn();

        Assert.True(enforced);
    }

    [Fact]
    public void CheckTamperAndVpnSkipsTamperCheckWhenSetSystemProxyIsFalse()
    {
        var api = new FakeApiClient();
        var config = new AgentConfig { ChildId = "child-1", DeviceId = "device-1", SetSystemProxy = false };
        var sync = new RuleSyncService(NullLogger<RuleSyncService>.Instance, CreateStore(), api, config)
        {
            ProxyRunningReader = () => true,
            ReadRegistryValue = new Dictionary<string, object?> { ["ProxyEnable"] = 0, ["ProxyServer"] = "127.0.0.1:8877" }.GetValueOrDefault,
            VpnInterfacesReader = () => [new TamperChecks.VpnInterfaceInfo("Ethernet", "Intel Ethernet", IsUp: true)],
            EnsureProxyEnforced = () => Assert.Fail("EnsureProxyEnforced should not be called when SetSystemProxy is false"),
        };

        sync.CheckTamperAndVpn();

        Assert.Empty(api.Alerts);
    }

    [Fact]
    public void CheckTamperAndVpnRaisesTheContractVpnAlert()
    {
        var (api, sync) = CreateSync(
            proxyRunning: true,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 1, ["ProxyServer"] = "127.0.0.1:8877" },
            interfaces: [new TamperChecks.VpnInterfaceInfo("Ethernet", "Intel Ethernet", IsUp: true),
                         new TamperChecks.VpnInterfaceInfo("wg", "WireGuard Tunnel", IsUp: true)]);

        sync.CheckTamperAndVpn();

        var alert = Assert.Single(api.Alerts);
        Assert.Equal("vpn_detected", alert.Category);
        Assert.Equal("warning", alert.Severity);
        Assert.Equal("VPN active", alert.Title);
        Assert.Equal("A VPN tunnel may be routing traffic around the filter", alert.Body);
        Assert.Equal("vpn_interface", alert.Metadata?["type"]);
        Assert.Equal("wg", alert.Metadata?["interface"]);
    }

    [Fact]
    public void HealthyProxyAndNoVpnRaiseNothing()
    {
        var (api, sync) = CreateSync(
            proxyRunning: true,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 1, ["ProxyServer"] = "127.0.0.1:8877" },
            interfaces: [new TamperChecks.VpnInterfaceInfo("Ethernet", "Intel Ethernet", IsUp: true)]);

        sync.CheckTamperAndVpn();

        Assert.Empty(api.Alerts);
    }

    [Fact]
    public void DisabledProxyWhileAgentProxyIsDownRaisesNothing()
    {
        var (api, sync) = CreateSync(
            proxyRunning: false,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 0 },
            interfaces: []);

        sync.CheckTamperAndVpn();

        Assert.Empty(api.Alerts);
    }

    [Fact]
    public void DownVpnInterfaceRaisesNothing()
    {
        var (api, sync) = CreateSync(
            proxyRunning: true,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 1, ["ProxyServer"] = "127.0.0.1:8877" },
            interfaces: [new TamperChecks.VpnInterfaceInfo("tap0", "tap", IsUp: false)]);

        sync.CheckTamperAndVpn();

        Assert.Empty(api.Alerts);
    }

    [Fact]
    public void UnpairedAgentRaisesNothing()
    {
        var api = new FakeApiClient();
        var sync = new RuleSyncService(NullLogger<RuleSyncService>.Instance, CreateStore(),
            api, new AgentConfig())
        {
            ProxyRunningReader = () => true,
            ReadRegistryValue = _ => 0,
            VpnInterfacesReader = () => [new TamperChecks.VpnInterfaceInfo("tun0", "tun", IsUp: true)],
            EnsureProxyEnforced = () => { },
        };

        sync.CheckTamperAndVpn();

        Assert.Empty(api.Alerts);
    }

    [Fact]
    public void EachAlertFamilyIsThrottledToOnePerHour()
    {
        var (api, sync) = CreateSync(
            proxyRunning: true,
            proxySettings: new Dictionary<string, object?> { ["ProxyEnable"] = 0 },
            interfaces: [new TamperChecks.VpnInterfaceInfo("tun0", "tun", IsUp: true)]);

        sync.CheckTamperAndVpn();
        sync.CheckTamperAndVpn();
        sync.CheckTamperAndVpn();
        Assert.Equal(2, api.Alerts.Count); // one tamper + one vpn, no duplicates

        // Rewind both throttle windows past the 1 h mark: both families alert again.
        sync.LastTamperAlertUtc = DateTime.UtcNow - TimeSpan.FromHours(2);
        sync.LastVpnAlertUtc = DateTime.UtcNow - TimeSpan.FromHours(2);
        sync.CheckTamperAndVpn();
        Assert.Equal(4, api.Alerts.Count);
        Assert.Equal(2, api.Alerts.Count(a => a.Category == "tamper"));
        Assert.Equal(2, api.Alerts.Count(a => a.Category == "vpn_detected"));
    }

    private (FakeApiClient Api, RuleSyncService Sync) CreateSync(
        bool proxyRunning, Dictionary<string, object?> proxySettings, IReadOnlyList<TamperChecks.VpnInterfaceInfo> interfaces)
    {
        var api = new FakeApiClient();
        var config = new AgentConfig { ChildId = "child-1", DeviceId = "device-1" };
        var sync = new RuleSyncService(NullLogger<RuleSyncService>.Instance, CreateStore(),
            api, config)
        {
            ProxyRunningReader = () => proxyRunning,
            ReadRegistryValue = proxySettings.GetValueOrDefault,
            VpnInterfacesReader = () => interfaces,
            EnsureProxyEnforced = () => { },
        };
        return (api, sync);
    }

    private sealed class FakeApiClient : ApiClient
    {
        public List<AlertDto> Alerts { get; } = [];

        public FakeApiClient() : base(new HttpClient(), new AgentConfig())
        {
        }

        public override Task<bool> PostAlert(AlertDto alert, CancellationToken ct = default)
        {
            Alerts.Add(alert);
            return Task.FromResult(true);
        }
    }
}
