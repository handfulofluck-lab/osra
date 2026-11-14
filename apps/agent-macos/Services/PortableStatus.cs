using System.Text.Json;

namespace FamilyShield.Agent.MacOS.Services;

/// <summary>Writes a placeholder status.json every 60 s so the Mac agent folder builds and runs as proven scaffolding.</summary>
public sealed class PortableStatus
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(60);

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    /// <summary>User profile root used to locate the Application Support folder (~ on macOS).</summary>
    internal static string UserProfilePath =>
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>~/Library/Application Support/OSRA/status.json (created on first write; migrated from FamilyShield, issue #608).</summary>
    internal static string StatusPath =>
        Path.Combine(DataFolderMigration.CurrentFolder(UserProfilePath), "status.json");

    /// <summary>
    /// Writes an initial status file then rewrites it every 60 s until cancelled. Returns the process
    /// exit code: 0 on success, 1 when the one-time data-folder migration failed (a clear message is
    /// written to stderr in that case).
    /// </summary>
    public static async Task<int> RunAsync(CancellationToken ct = default)
    {
        var outcome = DataFolderMigration.MigrateOnce(UserProfilePath, out var error);
        if (outcome == MigrationOutcome.Failed)
        {
            Console.Error.WriteLine(
                $"OSRA: could not migrate the legacy '{DataFolderMigration.LegacyFolderName}' data folder to '{DataFolderMigration.CurrentFolder(UserProfilePath)}': {error}");
            return 1;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(StatusPath)!);
        using var timer = new PeriodicTimer(Interval);
        do
        {
            Write("scaffolding");
        }
        while (await timer.WaitForNextTickAsync(ct));

        return 0;
    }

    /// <summary>Persists the placeholder status payload; real pause/telemetry fields land with the ported services (MAC-01).</summary>
    internal static void Write(string state, DateTimeOffset? now = null)
    {
        var payload = new Dictionary<string, object?>
        {
            ["state"] = state,
            ["enforcing"] = false, // scaffolding only; not actively enforcing rules
            ["paused"] = false, // placeholder until pause_internet (#11) is ported onto NetworkExtension
            ["updatedAt"] = (now ?? DateTimeOffset.UtcNow).ToString("O"),
        };
        File.WriteAllText(StatusPath, JsonSerializer.Serialize(payload, JsonOptions));
    }
}
