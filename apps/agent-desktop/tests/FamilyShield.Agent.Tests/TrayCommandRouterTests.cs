using System.Text.Json;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayCommandRouterTests
{
    [Theory]
    [InlineData("lock", TrayMessageKind.@lock)]
    [InlineData("unlock", TrayMessageKind.unlock)]
    [InlineData("pause", TrayMessageKind.pause)]
    [InlineData("resume", TrayMessageKind.resume)]
    [InlineData("ring", TrayMessageKind.ring)]
    public void ParentCommandsMapToTypedTrayMessages(string type, TrayMessageKind expected)
    {
        var message = TrayCommandRouter.Route(new DeviceCommandDto { Type = type });
        Assert.NotNull(message);
        Assert.Equal(expected, message.Kind);
        Assert.Null(message.Payload);
    }

    [Fact]
    public void WindDownCarriesOnlyMinutesAndRejectsInvalidInput()
    {
        var message = TrayCommandRouter.Route(new DeviceCommandDto { Type = "wind_down", Payload = JsonDocument.Parse("{\"minutes\":\"15\"}").RootElement.Clone() });
        Assert.NotNull(message);
        Assert.Equal(TrayMessageKind.wind_down, message.Kind);
        Assert.Equal(15, message.Payload!.Value.GetProperty("minutes").GetInt32());
        Assert.Null(TrayCommandRouter.Route(new DeviceCommandDto { Type = "wind_down", Payload = JsonDocument.Parse("{\"minutes\":0}").RootElement.Clone() }));
        Assert.Null(TrayCommandRouter.Route(new DeviceCommandDto { Type = "wind_down" }));
        Assert.Null(TrayCommandRouter.Route(new DeviceCommandDto { Type = "unknown" }));
    }

    [Fact]
    public async Task SessionQueueFlushesAfterTheConnectionArrives()
    {
        var stream = new MemoryStream();
        var server = new FakeServer(stream);
        var slot = new TrayServerWorker.SessionSlot(
            new InteractiveSession(7, "user", true), server,
            (_, _, _) => Task.FromResult<TrayMessage?>(null), NullLogger<TrayServerWorker>.Instance);
        slot.Enqueue(new TrayMessage(TrayMessageKind.@lock));

        await slot.RunAsync(CancellationToken.None);

        var message = await TrayProtocol.ReadAsync(new MemoryStream(stream.ToArray()), TrayDirection.ToTray);
        Assert.Equal(TrayMessageKind.@lock, message.Kind);
    }

    private sealed class FakeServer(MemoryStream stream) : ITrayServer
    {
        public Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(new TrayPipeConnection(stream, 7, "user"));
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
