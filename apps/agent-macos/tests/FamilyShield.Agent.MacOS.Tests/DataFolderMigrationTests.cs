using FamilyShield.Agent.MacOS.Services;
using Xunit;

namespace FamilyShield.Agent.MacOS.Tests;

/// <summary>
/// Issue #608: the macOS data folder moves from "FamilyShield" to "OSRA" with a one-time
/// migration. These tests drive <see cref="DataFolderMigration.MigrateOnce"/> against real temp
/// directories so the target runs on Windows/Linux as a pure net8.0 project.
/// </summary>
public sealed class DataFolderMigrationTests : IDisposable
{
    private readonly string _root;

    public DataFolderMigrationTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "osra-macos-migration", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private string Legacy => DataFolderMigration.LegacyFolder(_root);

    private string Current => DataFolderMigration.CurrentFolder(_root);

    private static void WriteFile(string directory, string relativePath, string content)
    {
        var full = Path.Combine(directory, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        File.WriteAllText(full, content);
    }

    [Fact]
    public void Old_only_renames_legacy_folder_and_preserves_every_file()
    {
        WriteFile(Legacy, "status.json", """{"state":"scaffolding"}""");
        WriteFile(Legacy, "pairing/agent.json", """{"childId":"c-1"}""");

        var outcome = DataFolderMigration.MigrateOnce(_root, out var error);

        Assert.Equal(MigrationOutcome.Migrated, outcome);
        Assert.Null(error);
        Assert.False(Directory.Exists(Legacy));
        Assert.True(Directory.Exists(Current));
        Assert.Equal("""{"state":"scaffolding"}""", File.ReadAllText(Path.Combine(Current, "status.json")));
        Assert.Equal("""{"childId":"c-1"}""", File.ReadAllText(Path.Combine(Current, "pairing", "agent.json")));
    }

    [Fact]
    public void Second_run_after_migration_is_idempotent()
    {
        WriteFile(Legacy, "status.json", "{}");

        Assert.Equal(MigrationOutcome.Migrated, DataFolderMigration.MigrateOnce(_root, out _));
        Assert.Equal(MigrationOutcome.NoMigration, DataFolderMigration.MigrateOnce(_root, out _));

        Assert.True(Directory.Exists(Current));
        Assert.False(Directory.Exists(Legacy));
    }

    [Fact]
    public void Both_present_leaves_each_folder_intact()
    {
        WriteFile(Legacy, "legacy-only.txt", "old");
        WriteFile(Current, "current-only.txt", "new");

        var outcome = DataFolderMigration.MigrateOnce(_root, out var error);

        Assert.Equal(MigrationOutcome.NoMigration, outcome);
        Assert.Null(error);
        Assert.True(Directory.Exists(Legacy));
        Assert.True(Directory.Exists(Current));
        Assert.Equal("old", File.ReadAllText(Path.Combine(Legacy, "legacy-only.txt")));
        Assert.Equal("new", File.ReadAllText(Path.Combine(Current, "current-only.txt")));
    }

    [Fact]
    public void Neither_present_is_a_no_op()
    {
        Assert.Equal(MigrationOutcome.NoMigration, DataFolderMigration.MigrateOnce(_root, out _));

        Assert.False(Directory.Exists(Legacy));
        Assert.False(Directory.Exists(Current));
    }

    [Fact]
    public void Move_failure_reports_failed_and_leaves_legacy_data_intact()
    {
        WriteFile(Legacy, "pairing/agent.json", """{"childId":"c-1"}""");
        File.WriteAllText(Current, "blocker"); // destination exists as a file, so Move cannot rename onto it

        var outcome = DataFolderMigration.MigrateOnce(_root, out var error);

        Assert.Equal(MigrationOutcome.Failed, outcome);
        Assert.False(string.IsNullOrWhiteSpace(error));
        Assert.True(Directory.Exists(Legacy));
        Assert.Equal("""{"childId":"c-1"}""", File.ReadAllText(Path.Combine(Legacy, "pairing", "agent.json")));
        Assert.True(File.Exists(Current));
    }

    [Fact]
    public void Active_status_path_lives_under_the_osra_folder()
    {
        var path = PortableStatus.StatusPath;

        Assert.EndsWith(Path.Combine("Library", "Application Support", "OSRA", "status.json"), path);
        Assert.DoesNotContain(Path.Combine("Library", "Application Support", DataFolderMigration.LegacyFolderName), path);
    }
}
