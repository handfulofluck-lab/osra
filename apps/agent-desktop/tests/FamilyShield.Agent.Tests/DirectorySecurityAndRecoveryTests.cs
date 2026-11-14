using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class DirectorySecurityAndRecoveryTests
{
    private static readonly DateTime Start = new(2026, 11, 14, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void UntrustedDirectoryFailsClosedInsteadOfFreeingTheDevice()
    {
        var directory = NewDirectory();
        var info = new DirectoryInfo(directory);
        var security = info.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!,
            FileSystemRights.FullControl, AccessControlType.Allow));
        info.SetAccessControl(security);
        var state = new DesktopRestrictionState(new FileDesktopRestrictionStore(Path.Combine(directory, "restrictions.json")));

        Assert.True(state.NeedsFallback(7, Start));
        Assert.Equal(TrayMessageKind.@lock, Assert.Single(state.MessagesFor(7, Start)).Kind);
        Assert.True(state.MarkFallback(7, Start));
        Assert.False(state.NeedsFallback(7, Start.AddSeconds(1)));
        Assert.False(state.MarkFallback(7, Start.AddSeconds(1)));
    }

    [Fact]
    public void StoreProtectsDirectoryBeforeUse()
    {
        var directory = NewDirectory();
        var store = new FileDesktopRestrictionStore(Path.Combine(directory, "restrictions.json"),
            directoryIsTrusted: _ => true);

        Assert.Empty(store.Load());
        var security = new DirectoryInfo(directory).GetAccessControl();
        Assert.True(security.AreAccessRulesProtected);
        AssertNoOtherWriters(security);
    }

    [Fact]
    public void TemporaryFileSecurityAllowsOnlySystemAndAdministrators()
    {
        var security = FileDesktopRestrictionStore.ProtectedFile();

        Assert.True(security.AreAccessRulesProtected);
        AssertNoOtherWriters(security);
        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>();
        Assert.Contains(rules, rule => rule.IdentityReference.Value == "S-1-5-18" &&
                                      rule.FileSystemRights == FileSystemRights.FullControl);
        Assert.Contains(rules, rule => rule.IdentityReference.Value == "S-1-5-32-544" &&
                                      rule.FileSystemRights == FileSystemRights.FullControl);
    }

    [Fact]
    public void CorruptStateLocksAndAlertsWithoutCrashing()
    {
        var unreadable = Assert.Single(FileDesktopRestrictionStore.Deserialize("not-json"));
        Assert.True(unreadable.Locked);
        Assert.True(unreadable.Unreadable);
        var store = new MemoryDesktopRestrictionStore([unreadable]);
        var state = new DesktopRestrictionState(store);

        Assert.True(state.NeedsFallback(7, Start));
        Assert.Equal(TrayMessageKind.@lock, Assert.Single(state.MessagesFor(7, Start)).Kind);
        Assert.True(state.MarkFallback(7, Start));
        Assert.False(state.NeedsFallback(7, Start.AddSeconds(1)));
        Assert.False(state.MarkFallback(7, Start.AddSeconds(1)));
        Assert.False(store.Load().Single(saved => saved.SessionId == 7).Unreadable);
    }

    [Fact]
    public void MissingDirectoryIsCreatedForAnEmptyStore()
    {
        var root = NewDirectory();
        var directory = Path.Combine(root, "new");
        var store = new FileDesktopRestrictionStore(Path.Combine(directory, "restrictions.json"),
            directoryIsTrusted: _ => true);

        Assert.Empty(store.Load());
        AssertNoOtherWriters(new DirectoryInfo(directory).GetAccessControl());
    }

    [Fact]
    public void MissingFileStartsWithoutARestriction()
    {
        var directory = NewDirectory();
        var state = new DesktopRestrictionState(new FileDesktopRestrictionStore(
            Path.Combine(directory, "restrictions.json"), directoryIsTrusted: _ => true));

        Assert.Empty(state.MessagesFor(7, Start));
        Assert.False(state.NeedsFallback(7, Start.AddDays(1)));
    }

    [Fact]
    public void UnreadableStateNeedsFallbackEvenWhenConnected()
    {
        var store = new MemoryDesktopRestrictionStore([
            new SessionRestriction { SessionId = 0, Locked = true, Unreadable = true, ObservedAt = Start },
        ]);
        var state = new DesktopRestrictionState(store);
        state.MarkConnected(7, Start);

        Assert.True(state.NeedsFallback(7, Start));
    }

    [Fact]
    public void ConnectedRestrictedSessionDoesNotNeedFallback()
    {
        var state = new DesktopRestrictionState();
        state.Observe(7, new TrayMessage(TrayMessageKind.@lock), Start);
        state.MarkConnected(7, Start);

        Assert.False(state.NeedsFallback(7, Start.AddDays(1)));
    }

    [Fact]
    public void UnlockClearsDisconnectedSessionsToo()
    {
        var state = new DesktopRestrictionState();
        state.Observe(7, new TrayMessage(TrayMessageKind.@lock), Start);

        state.ObserveDevice(new TrayMessage(TrayMessageKind.unlock), Start);

        Assert.Empty(state.MessagesFor(7, Start));
        Assert.False(state.NeedsFallback(7, Start.AddSeconds(20)));
    }

    private static string NewDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "osra-store-security", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static void AssertNoOtherWriters(FileSystemSecurity security)
    {
        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>().ToArray();
        var write = FileSystemRights.FullControl | FileSystemRights.Modify | FileSystemRights.Write |
                    FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
                    FileSystemRights.CreateFiles | FileSystemRights.CreateDirectories;
        Assert.DoesNotContain(rules, rule =>
            rule.AccessControlType == AccessControlType.Allow &&
            !rule.IdentityReference.Value.Equals("S-1-5-18") &&
            !rule.IdentityReference.Value.Equals("S-1-5-32-544") &&
            (rule.FileSystemRights & write) != 0);
    }

    private sealed class MemoryDesktopRestrictionStore : IRestrictionStore
    {
        private string _json;

        public MemoryDesktopRestrictionStore(IReadOnlyList<SessionRestriction> saved) =>
            _json = JsonSerializer.Serialize(saved);

        public IReadOnlyList<SessionRestriction> Load() =>
            JsonSerializer.Deserialize<List<SessionRestriction>>(_json)!;

        public void Save(IReadOnlyList<SessionRestriction> restrictions) =>
            _json = JsonSerializer.Serialize(restrictions);
    }
}
