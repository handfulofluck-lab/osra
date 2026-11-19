namespace FamilyShield.Agent.Services;

/// <summary>
/// The single source of truth for the user-visible per-user data folder. Issue #608 renamed the
/// folder from <c>FamilyShield</c> to <c>OSRA</c>; the legacy name is kept only so startup can
/// migrate an existing install without orphaning its pairing/data.
/// </summary>
public static class DataFolder
{
    /// <summary>New user-visible folder name (issue #608).</summary>
    public const string FolderName = "OSRA";

    /// <summary>Pre-rename folder name, used only by the one-time migration.</summary>
    public const string LegacyFolderName = "FamilyShield";

    /// <summary>Current per-user data folder: %LOCALAPPDATA%\OSRA.</summary>
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        FolderName);

    /// <summary>Legacy per-user data folder: %LOCALAPPDATA%\FamilyShield.</summary>
    public static string LegacyPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        LegacyFolderName);

    /// <summary>
    /// One-time migration: moves the legacy folder to the current folder only when the legacy
    /// folder exists and the current one does not. Returns true only when a move happened. An
    /// existing current folder is never overwritten or deleted (no data loss), and a missing
    /// legacy folder is a no-op, so the call is idempotent across startups. IO errors (for
    /// example a locked file) propagate so the caller can fail loudly instead of silently
    /// starting against an empty OSRA folder and orphaning a paired install's data.
    /// </summary>
    public static bool MigrateOnce(string? legacyPath = null, string? currentPath = null)
    {
        var legacy = string.IsNullOrWhiteSpace(legacyPath) ? LegacyPath : legacyPath;
        var current = string.IsNullOrWhiteSpace(currentPath) ? DefaultPath : currentPath;

        if (!Directory.Exists(legacy)) return false;
        if (Directory.Exists(current)) return false;
        Directory.Move(legacy, current);
        return true;
    }
}
