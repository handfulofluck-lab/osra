using System.IO;

namespace FamilyShield.Agent.MacOS.Services;

/// <summary>Result of a one-time data-folder migration attempt.</summary>
public enum MigrationOutcome
{
    /// <summary>There was nothing to migrate (both folders absent, already migrated, or both present).</summary>
    NoMigration,

    /// <summary>The legacy folder was renamed to the current folder.</summary>
    Migrated,

    /// <summary>The rename failed; the legacy folder is left intact and an error message is available.</summary>
    Failed,
}

/// <summary>
/// One-time migration of the legacy "FamilyShield" Application Support folder to the "OSRA"
/// folder (issue #608). The legacy folder is renamed when the OSRA folder does not yet exist,
/// which preserves every file — pairing state included. When both folders already exist nothing
/// is moved, overwritten or deleted, so neither side loses data. A failed rename is reported
/// rather than thrown, and always leaves the legacy folder untouched.
/// </summary>
public static class DataFolderMigration
{
    /// <summary>Legacy (pre-rename) user-visible data folder name under Application Support.</summary>
    public const string LegacyFolderName = "FamilyShield";

    /// <summary>Current user-visible data folder name under Application Support.</summary>
    public const string FolderName = "OSRA";

    /// <summary>Resolves the macOS Application Support root for a user profile ("~/Library/Application Support").</summary>
    public static string ApplicationSupportRoot(string userProfile) =>
        Path.Combine(userProfile, "Library", "Application Support");

    /// <summary>Legacy folder path: <c>~/Library/Application Support/FamilyShield</c>.</summary>
    public static string LegacyFolder(string userProfile) =>
        Path.Combine(ApplicationSupportRoot(userProfile), LegacyFolderName);

    /// <summary>Current folder path: <c>~/Library/Application Support/OSRA</c>.</summary>
    public static string CurrentFolder(string userProfile) =>
        Path.Combine(ApplicationSupportRoot(userProfile), FolderName);

    /// <summary>
    /// Performs the one-time migration. On an I/O failure (a rename that cannot complete) it returns
    /// <see cref="MigrationOutcome.Failed"/> with a message in <paramref name="error"/> and leaves the
    /// legacy folder untouched. Idempotent: a second run after a successful migration finds the current
    /// folder present and the legacy folder gone, so it returns <see cref="MigrationOutcome.NoMigration"/>
    /// and changes nothing.
    /// </summary>
    public static MigrationOutcome MigrateOnce(string userProfile, out string? error)
    {
        error = null;
        var legacy = LegacyFolder(userProfile);
        var current = CurrentFolder(userProfile);

        // Nothing to migrate, or the destination already exists: never overwrite or delete.
        if (!Directory.Exists(legacy) || Directory.Exists(current))
        {
            return MigrationOutcome.NoMigration;
        }

        try
        {
            Directory.Move(legacy, current);
            return MigrationOutcome.Migrated;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            error = ex.Message;
            return MigrationOutcome.Failed;
        }
    }
}
