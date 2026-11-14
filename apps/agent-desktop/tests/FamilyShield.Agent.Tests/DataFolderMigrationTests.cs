using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Fail-first tests for the one-time %LOCALAPPDATA%\FamilyShield → %LOCALAPPDATA%\OSRA migration
/// (issue #608). Every test uses only temp directories — never the live user data folder.
/// </summary>
public sealed class DataFolderMigrationTests : IDisposable
{
    private readonly string _root;
    private readonly string _legacy;
    private readonly string _current;

    public DataFolderMigrationTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "osra-migration-tests", Guid.NewGuid().ToString("N"));
        _legacy = Path.Combine(_root, DataFolder.LegacyFolderName);
        _current = Path.Combine(_root, DataFolder.FolderName);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch (Exception) { }
    }

    [Fact]
    public void OldOnlyFolderIsMovedToOsraPreservingContents()
    {
        Directory.CreateDirectory(_legacy);
        File.WriteAllText(Path.Combine(_legacy, "agent.db"), "pairing-data");
        File.WriteAllText(Path.Combine(_legacy, "status.json"), "{}");

        var moved = DataFolder.MigrateOnce(_legacy, _current);

        Assert.True(moved);
        Assert.False(Directory.Exists(_legacy));
        Assert.True(Directory.Exists(_current));
        Assert.Equal("pairing-data", File.ReadAllText(Path.Combine(_current, "agent.db")));
        Assert.Equal("{}", File.ReadAllText(Path.Combine(_current, "status.json")));
    }

    [Fact]
    public void BothPresentLosesNeitherFolder()
    {
        Directory.CreateDirectory(_legacy);
        File.WriteAllText(Path.Combine(_legacy, "agent.db"), "old-pairing-data");
        Directory.CreateDirectory(_current);
        File.WriteAllText(Path.Combine(_current, "agent.db"), "new-pairing-data");

        var moved = DataFolder.MigrateOnce(_legacy, _current);

        Assert.False(moved);
        Assert.True(Directory.Exists(_legacy));
        Assert.True(Directory.Exists(_current));
        Assert.Equal("old-pairing-data", File.ReadAllText(Path.Combine(_legacy, "agent.db")));
        Assert.Equal("new-pairing-data", File.ReadAllText(Path.Combine(_current, "agent.db")));
    }

    [Fact]
    public void NeitherPresentIsANoOpAndRepeatable()
    {
        Assert.False(DataFolder.MigrateOnce(_legacy, _current));
        Assert.False(Directory.Exists(_current));
        Assert.False(DataFolder.MigrateOnce(_legacy, _current));
        Assert.False(Directory.Exists(_current));
    }

    [Fact]
    public void MigrationIsIdempotentAfterTheOldFolderIsGone()
    {
        Directory.CreateDirectory(_legacy);
        File.WriteAllText(Path.Combine(_legacy, "rootCert.pfx"), "pfx-bytes");

        Assert.True(DataFolder.MigrateOnce(_legacy, _current));
        // A second startup sees no legacy folder and must leave the OSRA folder untouched.
        Assert.False(DataFolder.MigrateOnce(_legacy, _current));
        Assert.Equal("pfx-bytes", File.ReadAllText(Path.Combine(_current, "rootCert.pfx")));
    }

    [Fact]
    public void MoveFailurePropagatesAndLeavesLegacyDataIntact()
    {
        Directory.CreateDirectory(_legacy);
        File.WriteAllText(Path.Combine(_legacy, "agent.db"), "pairing-data");
        // A FILE at the would-be current path makes Directory.Exists(_current) false (it only
        // reports directories) while Directory.Move throws — a deterministic move failure.
        File.WriteAllText(_current, "blocker");

        Assert.Throws<IOException>(() => DataFolder.MigrateOnce(_legacy, _current));

        // The failed move must not destroy or empty the legacy folder: pairing data stays put.
        Assert.True(Directory.Exists(_legacy));
        Assert.Equal("pairing-data", File.ReadAllText(Path.Combine(_legacy, "agent.db")));
        Assert.True(File.Exists(_current));
        Assert.Equal("blocker", File.ReadAllText(_current));
    }
}
