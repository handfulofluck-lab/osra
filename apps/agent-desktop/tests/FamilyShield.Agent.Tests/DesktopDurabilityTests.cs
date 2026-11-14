using System.Security.AccessControl;
using System.Security.Principal;
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
    public void StatePersistsWithOnlySystemAndAdminAccessAndRearmsEveryGracePeriod()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-restriction-store", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "restrictions.json");
        try
        {
            var store = new MemoryDesktopRestrictionStore();
            var first = new DesktopRestrictionState(store);
            first.ObserveDevice(new TrayMessage(TrayMessageKind.@lock), Start);
            first.MarkConnected(7, Start);
            Assert.True(first.MarkFallback(7, Start.AddSeconds(20)));

            var restored = new DesktopRestrictionState(store);
            Assert.Equal(TrayMessageKind.@lock, Assert.Single(restored.MessagesFor(7, Start.AddSeconds(21))).Kind);
            Assert.True(restored.NeedsFallback(7, Start.AddSeconds(40)));
            Assert.False(restored.MarkFallback(7, Start.AddSeconds(40)));
            Assert.True(restored.NeedsFallback(7, Start.AddSeconds(60)));

            File.WriteAllText(path, "[]");
            new FileDesktopRestrictionStore(path, (_, _) => { }).Save([
                new SessionRestriction { SessionId = 0, Locked = true, ObservedAt = Start },
            ]);
            var rules = new FileInfo(path + ".tmp").GetAccessControl().GetAccessRules(true, false, typeof(SecurityIdentifier))
                .Cast<FileSystemAccessRule>().ToArray();
            Assert.DoesNotContain(rules, rule => rule.IdentityReference.Value is "S-1-1-0" or "S-1-5-11" or "S-1-5-32-545");
            Assert.Contains(rules, rule => rule.IdentityReference.Value == "S-1-5-18" && rule.AccessControlType == AccessControlType.Allow);
            Assert.Contains(rules, rule => rule.IdentityReference.Value == "S-1-5-32-544" && rule.AccessControlType == AccessControlType.Allow);
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private sealed class MemoryDesktopRestrictionStore : IRestrictionStore
    {
        private string? _json;

        public IReadOnlyList<SessionRestriction> Load() =>
            _json is null ? [] : JsonSerializer.Deserialize<List<SessionRestriction>>(_json)!;

        public void Save(IReadOnlyList<SessionRestriction> restrictions) =>
            _json = JsonSerializer.Serialize(restrictions);
    }
}
