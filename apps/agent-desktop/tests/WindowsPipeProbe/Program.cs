using System.Diagnostics;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

if (args.Length > 0 && args[0] == "client") return await RunClient();
return await RunService(args);

static async Task<int> RunClient()
{
    var sessionId = Process.GetCurrentProcess().SessionId;
    for (var attempt = 0; attempt < 40; attempt++)
    {
        try
        {
            await using var client = new TrayPipeClient();
            await using var connection = await client.ConnectAsync(sessionId, CancellationToken.None);
            var message = await TrayProtocol.ReadAsync(connection.Stream, TrayDirection.ToTray);
            if (message.Kind != TrayMessageKind.@lock) return 4;
            Console.WriteLine("OSRA_PIPE_PROBE_PASS");
            return 0;
        }
        catch (UnauthorizedAccessException)
        {
            return 3;
        }
        catch (Exception ex) when (ex is IOException or TimeoutException)
        {
            await Task.Delay(250);
        }
    }
    return 2;
}

static async Task<int> RunService(string[] args)
{
    if (args.Length != 5 || args[0] != "server" ||
        !int.TryParse(args[1], out var sessionId) || !int.TryParse(args[3], out var expectedPid))
    {
        return 64;
    }
    var settings = new ProbeSettings(sessionId, args[2], expectedPid, args[4]);
    var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
    {
        Args = args,
        ContentRootPath = AppContext.BaseDirectory,
    });
    builder.Services.AddWindowsService(options => options.ServiceName = "OSRAPipeProbe-K31");
    builder.Services.AddSingleton(settings);
    builder.Services.AddHostedService<ProbeServer>();
    await builder.Build().RunAsync();
    return 0;
}

sealed record ProbeSettings(int SessionId, string UserSid, int ExpectedPid, string ImagePath);

sealed class ProbeServer(ProbeSettings settings) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await using var server = new TrayPipeServer(settings.SessionId, settings.UserSid, settings.ExpectedPid,
            expectedImagePath: settings.ImagePath);
        var connection = await server.AcceptAsync(stoppingToken);
        await TrayProtocol.WriteAsync(connection.Stream, new TrayMessage(TrayMessageKind.@lock), TrayDirection.ToTray, stoppingToken);

        var store = new FileDesktopRestrictionStore(Path.Combine(AppContext.BaseDirectory, "probe-restrictions.json"));
        store.Save([new SessionRestriction { SessionId = settings.SessionId, Locked = true, ObservedAt = DateTime.UtcNow }]);
        store.Save([new SessionRestriction
        {
            SessionId = settings.SessionId,
            Locked = true,
            ObservedAt = DateTime.UtcNow,
            FallbackAt = DateTime.UtcNow,
        }]);
        var restored = store.Load();
        if (restored.Count != 1 || !restored[0].Locked || restored[0].FallbackAt is null)
            throw new InvalidDataException("The SYSTEM restriction store did not round-trip.");
        Console.WriteLine("OSRA_SERVICE_STORE_PASS");
        await connection.DisposeAsync();
    }
}
