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

    /// <summary>~/Library/Application Support/FamilyShield/status.json (created on first write).</summary>
    internal static string StatusPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "FamilyShield", "status.json");

    /// <summary>Writes an initial status file then rewrites it every 60 s until cancelled.</summary>
    public static async Task RunAsync(CancellationToken ct = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(StatusPath)!);
        using var timer = new PeriodicTimer(Interval);
        do
        {
            Write("ok");
        }
        while (await timer.WaitForNextTickAsync(ct));
    }

    /// <summary>Persists the placeholder status payload; real pause/telemetry fields land with the ported services.</summary>
    internal static void Write(string state, DateTimeOffset? now = null)
    {
        var payload = new Dictionary<string, object?>
        {
            ["state"] = state,
            ["paused"] = false, // placeholder until pause_internet (#11) is ported onto NetworkExtension
            ["updatedAt"] = (now ?? DateTimeOffset.UtcNow).ToString("O"),
        };
        File.WriteAllText(StatusPath, JsonSerializer.Serialize(payload, JsonOptions));
    }
}
