using FamilyShield.Agent.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using OSRA.Service;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopCompositionTests
{
    [Fact]
    public async Task ServiceAndTrayResolveOneWorkerPerHost()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-composition-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var services = new ServiceCollection().AddLogging();
            services.AddSingleton<IInteractiveSessionSource>(new FakeSessions([]));
            services.AddSingleton<ITrayProcessRegistry>(new FakeRegistry());
            DesktopRuntime.AddServiceTransport(services, new AgentConfig { ApiBase = AgentConfig.ProductionApiBase }, new TrayServerEvents());
            var storeRegistration = Assert.Single(services.Where(descriptor => descriptor.ServiceType == typeof(IRestrictionStore)));
            Assert.Equal(typeof(FileDesktopRestrictionStore), storeRegistration.ImplementationType);
            services.Remove(storeRegistration);
            services.AddSingleton<IRestrictionStore>(new FileDesktopRestrictionStore(
                Path.Combine(directory, "restrictions.json"), directoryIsTrusted: _ => true));
            UseStore(services, store);
            await using var provider = services.BuildServiceProvider();

            var sink = provider.GetRequiredService<ITrayCommandSink>();
            var worker = provider.GetRequiredService<IEnumerable<IHostedService>>().OfType<TrayServerWorker>().Single();
            Assert.Same(sink, worker);
            Assert.IsType<FileDesktopRestrictionStore>(provider.GetRequiredService<IRestrictionStore>());

            var trayServices = new ServiceCollection().AddLogging();
            DesktopRuntime.AddTray(trayServices, new AgentConfig { ApiBase = AgentConfig.ProductionApiBase });
            UseStore(trayServices, store);
            await using var trayProvider = trayServices.BuildServiceProvider();
            var traySink = trayProvider.GetRequiredService<ITrayCommandSink>();
            var trayWorker = trayProvider.GetRequiredService<IEnumerable<IHostedService>>().OfType<TrayPipeClientWorker>().Single();
            Assert.Same(traySink, trayWorker);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public async Task PairingEventStartsTheComposedRuntimeCoordinator()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-composition-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var transport = new AgentConfig { ApiBase = AgentConfig.ProductionApiBase };
            var sink = new FakeSink();
            var capabilities = new DesktopCapabilitiesStore();
            var host = new FakeHost();
            var coordinator = new RuntimeCoordinator(transport, store, sink, capabilities,
                () => new AgentConfig
                {
                    DeviceJwt = "identity-jwt",
                    DeviceId = "device-1",
                    ChildId = "child-1",
                    HmacSecret = "identity-hmac",
                    ParentPin = "4821",
                }, _ => host);
            var services = new ServiceCollection().AddLogging();
            ServiceHostComposition.ConfigureServices(services, null, coordinator);
            services.Remove(services.Last(descriptor => descriptor.ServiceType == typeof(LocalRuleStore)));
            services.AddSingleton(store);
            services.AddSingleton<IRestrictionStore>(new FileDesktopRestrictionStore(
                Path.Combine(directory, "restrictions.json"), directoryIsTrusted: _ => true));
            await using var provider = services.BuildServiceProvider();

            var events = provider.GetRequiredService<TrayServerEvents>();
            await events.PairingComplete(1, CancellationToken.None);

            Assert.True(coordinator.RuntimeStarted);
            Assert.Equal(1, host.StartCalls);
            Assert.Equal(AgentConfig.ProductionApiBase, transport.ApiBase);
            Assert.True(transport.SetSystemProxy);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private static void UseStore(IServiceCollection services, LocalRuleStore store)
    {
        foreach (var descriptor in services.Where(descriptor => descriptor.ServiceType == typeof(LocalRuleStore)).ToArray())
            services.Remove(descriptor);
        services.AddSingleton(store);
    }

    private sealed class FakeSessions(IReadOnlyList<InteractiveSession> sessions) : IInteractiveSessionSource
    {
        public IReadOnlyList<InteractiveSession> List() => sessions;
    }

    private sealed class FakeRegistry : ITrayProcessRegistry
    {
        public int? ProcessIdForSession(int sessionId) => 42;
    }

    private sealed class FakeSink : ITrayCommandSink
    {
        public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }

    private sealed class FakeHost : IHost
    {
        public int StartCalls { get; private set; }
        public IServiceProvider Services => throw new NotSupportedException();
        public Task StartAsync(CancellationToken cancellationToken = default)
        {
            StartCalls++;
            return Task.CompletedTask;
        }
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public void Dispose() { }
    }
}
