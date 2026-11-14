using FamilyShield.Agent.Services;
using OSRA.Service;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class RuntimeCoordinatorTests
{
    [Fact]
    public async Task UnpairedServiceStartsRuntimeOnlyAfterPairingAndOnlyOnce()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-runtime-tests", Guid.NewGuid().ToString("N"));
        var transport = new AgentConfig { ApiBase = AgentConfig.ProductionApiBase };
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(dir, "agent.db"), Path.Combine(dir, "status.json"));
        var sink = new FakeSink();
        var capabilities = new DesktopCapabilitiesStore();
        AgentConfig? stored = null;
        var loadCalls = 0;
        var host = new FakeHost();
        var coordinator = new RuntimeCoordinator(transport, store, sink, capabilities,
            () => { loadCalls++; return stored; }, config => { host.Config = config; return host; });

        await coordinator.StartPairedRuntime(1, CancellationToken.None);
        Assert.Equal(1, loadCalls);
        Assert.False(coordinator.RuntimeStarted);

        stored = new AgentConfig
        {
            ApiBase = "https://untrusted.invalid",
            DeviceJwt = "identity-jwt",
            DeviceId = "device-1",
            ChildId = "child-1",
            HmacSecret = "identity-hmac",
            ParentPin = "4821",
            SetSystemProxy = false,
        };
        await coordinator.StartPairedRuntime(1, CancellationToken.None);
        await coordinator.StartPairedRuntime(1, CancellationToken.None);

        Assert.Equal(2, loadCalls);
        Assert.Equal(1, host.StartCalls);
        Assert.True(coordinator.RuntimeStarted);
        Assert.Equal("identity-jwt", transport.DeviceJwt);
        Assert.Equal("device-1", transport.DeviceId);
        Assert.Equal("child-1", transport.ChildId);
        Assert.Equal("identity-hmac", transport.HmacSecret);
        Assert.Equal(AgentConfig.ProductionApiBase, transport.ApiBase);
        Assert.Null(transport.ParentPin);
        Assert.True(transport.SetSystemProxy);
        Assert.Equal("identity-jwt", host.Config!.DeviceJwt);
        Assert.Equal(AgentConfig.ProductionApiBase, host.Config.ApiBase);
        Assert.Null(host.Config.ParentPin);
        coordinator.Dispose();
        Assert.True(host.Disposed);
        store.Dispose();
        try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
    }

    [Fact]
    public void UnpairedTransportResolvesItsWorker()
    {
        var dir = Path.Combine(Path.GetTempPath(), "osra-runtime-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(dir, "agent.db"), Path.Combine(dir, "status.json"));
        try
        {
            var services = new ServiceCollection();
            services.AddLogging();
            ServiceHostComposition.ConfigureServices(services, null);
            services.Remove(services.Single(service => service.ServiceType == typeof(LocalRuleStore)));
            services.AddSingleton(store);
            using var provider = services.BuildServiceProvider();

            Assert.NotNull(provider.GetRequiredService<ITrayCommandSink>());
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(dir, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class FakeSink : ITrayCommandSink
    {
        public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }

    private sealed class FakeHost : IHost
    {
        public int StartCalls { get; private set; }
        public bool Disposed { get; private set; }
        public AgentConfig? Config { get; set; }
        public IServiceProvider Services => throw new NotSupportedException();
        public Task StartAsync(CancellationToken cancellationToken = default)
        {
            StartCalls++;
            return Task.CompletedTask;
        }
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public void Dispose() => Disposed = true;
    }
}
