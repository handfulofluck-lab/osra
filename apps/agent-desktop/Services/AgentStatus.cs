using System.Text.Json;
using System.Text.Json.Serialization;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Small status file (%LOCALAPPDATA%\FamilyShield\status.json) the parent-facing UI/tests read:
/// { paused, httpsInspect, proxyRunning, updatedAt }. Best-effort — never throws.
/// </summary>
public static class AgentStatus
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Volatile mirror of "the WebFilterProxy is bound" (Feature #19). WebFilterProxy sets it when
    /// the proxy starts/stops; every status write embeds it so readers (RuleSyncService tamper
    /// check, parent UI) see the bound state without a cross-service reference.
    /// </summary>
    internal static volatile bool ProxyRunning;

    /// <summary>Default status path beside the agent database.</summary>
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FamilyShield", "status.json");

    /// <summary>Serializes the current flags to the status file (temp-file + move so readers never see a torn file).</summary>
    public static void Write(bool paused, bool httpsInspect, string? path = null)
    {
        var target = string.IsNullOrWhiteSpace(path) ? DefaultPath : path;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var json = JsonSerializer.Serialize(new StatusDto
            {
                Paused = paused,
                HttpsInspect = httpsInspect,
                ProxyRunning = ProxyRunning,
                UpdatedAt = DateTime.UtcNow.ToString("O"),
            }, JsonOptions);
            var tmp = target + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, target, overwrite: true);
        }
        catch (Exception)
        {
            // status file is observability only; a failed write must never break the agent
        }
    }

    /// <summary>Reads the status file back; null when missing/corrupt.</summary>
    public static StatusDto? Read(string? path = null)
    {
        var target = string.IsNullOrWhiteSpace(path) ? DefaultPath : path;
        try
        {
            return File.Exists(target)
                ? JsonSerializer.Deserialize<StatusDto>(File.ReadAllText(target), JsonOptions)
                : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Wire shape of status.json.</summary>
    public sealed class StatusDto
    {
        /// <summary>True while the internet is paused (Feature #11).</summary>
        [JsonPropertyName("paused")] public bool Paused { get; set; }

        /// <summary>True while HTTPS inspection is enabled AND the root cert exists (Feature #3).</summary>
        [JsonPropertyName("httpsInspect")] public bool HttpsInspect { get; set; }

        /// <summary>True while the WebFilterProxy is bound on 127.0.0.1:8877 (Feature #19 tamper check).</summary>
        [JsonPropertyName("proxyRunning")] public bool ProxyRunning { get; set; }

        /// <summary>UTC ISO-8601 timestamp of the last write.</summary>
        [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    }
}
