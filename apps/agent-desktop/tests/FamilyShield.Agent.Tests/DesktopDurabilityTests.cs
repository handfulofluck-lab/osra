using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DesktopDurabilityTests
{
    private static readonly DateTime Start = new(2026, 11, 14, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void DeviceRestrictionWithoutASlotAppliesToANewSession()
    {
        var state = new DesktopRestrictionState();
        state.ObserveDevice(new TrayMessage(TrayMessageKind.@lock), Start);

        var first = Assert.Single(state.MessagesFor(7, Start));
        Assert.Equal(TrayMessageKind.@lock, first.Kind);
        Assert.True(state.NeedsFallback(7, Start.AddSeconds(20)));
    }

    [Fact]
    public void StatePersistsAndRestartsOfflineGraceWithoutAnInheritedAlert()
    {
        var store = new MemoryDesktopRestrictionStore();
        var first = new DesktopRestrictionState(store, clock: () => Start);
        first.ObserveDevice(new TrayMessage(TrayMessageKind.@lock), Start);
        first.MarkConnected(7, Start);
        Assert.True(first.MarkFallback(7, Start.AddSeconds(20)));

        var restoredAt = Start.AddSeconds(30);
        var restored = new DesktopRestrictionState(store, clock: () => restoredAt);
        Assert.Equal(TrayMessageKind.@lock, Assert.Single(restored.MessagesFor(7, restoredAt)).Kind);
        Assert.False(restored.NeedsFallback(7, restoredAt.AddSeconds(19)));
        Assert.True(restored.NeedsFallback(7, restoredAt.AddSeconds(20)));
        Assert.True(restored.MarkFallback(7, restoredAt.AddSeconds(20)));
        Assert.False(restored.NeedsFallback(7, restoredAt.AddSeconds(39)));
        Assert.True(restored.NeedsFallback(7, restoredAt.AddSeconds(40)));
    }

    [Fact]
    public void DeviceLockIsNotHiddenByAStaleSessionRecord()
    {
        var store = new MemoryDesktopRestrictionStore(
            new SessionRestriction { SessionId = 0, Locked = true, ObservedAt = Start.AddHours(-2) },
            new SessionRestriction { SessionId = 7, Paused = true, ObservedAt = Start.AddDays(-1) });
        var restored = new DesktopRestrictionState(store, clock: () => Start);

        Assert.Equal([TrayMessageKind.@lock, TrayMessageKind.pause],
            restored.MessagesFor(7, Start).Select(message => message.Kind).ToArray());
        Assert.False(restored.NeedsFallback(7, Start.AddSeconds(19)));
        Assert.True(restored.NeedsFallback(7, Start.AddSeconds(20)));
    }

    private sealed class MemoryDesktopRestrictionStore(params SessionRestriction[] initial) : IRestrictionStore
    {
        private string? _json = initial.Length == 0 ? null : JsonSerializer.Serialize(initial);

        public IReadOnlyList<SessionRestriction> Load() =>
            _json is null ? [] : JsonSerializer.Deserialize<List<SessionRestriction>>(_json)!;

        public void Save(IReadOnlyList<SessionRestriction> restrictions) =>
            _json = JsonSerializer.Serialize(restrictions);
    }
}
