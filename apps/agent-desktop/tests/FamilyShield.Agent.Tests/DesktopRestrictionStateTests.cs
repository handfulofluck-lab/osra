using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopRestrictionStateTests
{
    private static readonly DateTime Start = new(2026, 11, 14, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void CurrentStateIsReplayedAndCleared()
    {
        var state = new DesktopRestrictionState();
        state.Observe(7, new TrayMessage(TrayMessageKind.@lock), Start);
        state.Observe(7, new TrayMessage(TrayMessageKind.pause), Start);
        state.Observe(7, new TrayMessage(TrayMessageKind.wind_down, Minutes(15)), Start);

        var messages = state.MessagesFor(7, Start);

        Assert.Equal([TrayMessageKind.@lock, TrayMessageKind.pause, TrayMessageKind.wind_down],
            messages.Select(message => message.Kind).ToArray());
        Assert.Equal(15, messages[^1].Payload!.Value.GetProperty("minutes").GetInt32());
        state.Observe(7, new TrayMessage(TrayMessageKind.unlock), Start);
        Assert.Empty(state.MessagesFor(7, Start));
        state.Observe(7, new TrayMessage(TrayMessageKind.@lock), Start);
        state.Observe(7, new TrayMessage(TrayMessageKind.pause), Start);
        state.Observe(7, new TrayMessage(TrayMessageKind.resume), Start);
        Assert.Empty(state.MessagesFor(7, Start));
    }

    [Fact]
    public void OfflineEpisodeFallsBackOnceAndResetsOnReconnect()
    {
        var state = new DesktopRestrictionState();
        state.Observe(7, new TrayMessage(TrayMessageKind.@lock), Start);

        Assert.False(state.NeedsFallback(7, Start.AddSeconds(19.9)));
        Assert.True(state.NeedsFallback(7, Start.AddSeconds(20)));
        Assert.True(state.MarkFallback(7, Start.AddSeconds(20)));
        Assert.False(state.NeedsFallback(7, Start.AddSeconds(21)));
        Assert.False(state.MarkFallback(7, Start.AddSeconds(22)));
        Assert.Equal(TrayMessageKind.@lock, Assert.Single(state.MessagesFor(7, Start.AddSeconds(22))).Kind);

        state.MarkConnected(7, Start.AddSeconds(23));
        state.MarkDisconnected(7, Start.AddSeconds(24));
        Assert.False(state.NeedsFallback(7, Start.AddSeconds(43.9)));
        Assert.True(state.MarkFallback(7, Start.AddSeconds(44)));
    }

    [Fact]
    public void PipeFailureReportsOncePerEpisode()
    {
        var state = new DesktopRestrictionState();

        Assert.True(state.RecordPipeFailure(7));
        Assert.False(state.RecordPipeFailure(7));
        state.MarkConnected(7, Start);
        Assert.True(state.RecordPipeFailure(7));
        Assert.False(state.NeedsFallback(7, Start.AddDays(1)));
    }

    private static JsonElement Minutes(int value) =>
        JsonSerializer.SerializeToElement(new { minutes = value });
}
