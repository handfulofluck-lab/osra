using System.Text.Json;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Persistent agent identity (§14.3): stored as JSON in <see cref="FileName"/> beside the exe.
/// Values from the file are overridden by API_BASE / DEVICE_JWT / DEVICE_ID / CHILD_ID env vars.
/// </summary>
public sealed class AgentConfig
{
    /// <summary>Config file name, written next to the exe (AppContext.BaseDirectory).</summary>
    public const string FileName = "agent.config.json";

    private static readonly JsonSerializerOptions LoadOptions = new(JsonSerializerDefaults.Web);
    private static readonly JsonSerializerOptions SaveOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    /// <summary>Base URL of the FamilyShield backend.</summary>
    public string? ApiBase { get; set; }

    /// <summary>Device JWT issued by POST /v1/devices/pair/claim.</summary>
    public string? DeviceJwt { get; set; }

    /// <summary>This device's server-side id.</summary>
    public string? DeviceId { get; set; }

    /// <summary>The child this device enforces rules for.</summary>
    public string? ChildId { get; set; }

    /// <summary>Shared HMAC secret returned by pair/claim; signs /internal calls (alerts). Env INTERNAL_HMAC_SECRET overrides.</summary>
    public string? HmacSecret { get; set; }

    /// <summary>
    /// When false, the desktop agent does not configure or enforce the system-wide WinINET proxy.
    /// Default true. Environment variable FS_SET_SYSTEM_PROXY=0 overrides to false.
    /// </summary>
    public bool SetSystemProxy { get; set; } = true;

    /// <summary>
    /// Reads <paramref name="exeDir"/>/<see cref="FileName"/> and applies env overrides.
    /// Returns null when the file is corrupt, and when there is no usable identity — i.e. the
    /// missing-file first run, unless the env vars supply a complete identity themselves.
    /// </summary>
    public static AgentConfig? Load(string exeDir)
    {
        var path = Path.Combine(exeDir, FileName);
        AgentConfig? config = null;
        if (File.Exists(path))
        {
            try
            {
                config = JsonSerializer.Deserialize<AgentConfig>(File.ReadAllText(path), LoadOptions);
            }
            catch (Exception)
            {
                return null; // corrupt or unreadable file — treat as unconfigured so pairing can rewrite it
            }
        }

        config ??= new AgentConfig();
        config.ApiBase = Environment.GetEnvironmentVariable("API_BASE") ?? config.ApiBase;
        config.DeviceJwt = Environment.GetEnvironmentVariable("DEVICE_JWT") ?? config.DeviceJwt;
        config.DeviceId = Environment.GetEnvironmentVariable("DEVICE_ID") ?? config.DeviceId;
        config.ChildId = Environment.GetEnvironmentVariable("CHILD_ID") ?? config.ChildId;
        config.HmacSecret = Environment.GetEnvironmentVariable("INTERNAL_HMAC_SECRET") ?? config.HmacSecret;

        var setProxyEnv = Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY") ??
                          Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY", EnvironmentVariableTarget.User);
        if (!string.IsNullOrWhiteSpace(setProxyEnv))
        {
            config.SetSystemProxy = !string.Equals(setProxyEnv, "0", StringComparison.OrdinalIgnoreCase) &&
                                    !string.Equals(setProxyEnv, "false", StringComparison.OrdinalIgnoreCase);
        }

        // NOTE: "no device token" means "not paired" — that covers the missing-file first run while
        // still letting a fully env-provided identity (legacy deployments) run without any file.
        return string.IsNullOrWhiteSpace(config.DeviceJwt) ? null : config;
    }

    /// <summary>
    /// Writes indented JSON to <paramref name="exeDir"/>/<see cref="FileName"/>; skips the write
    /// when the content is unchanged (avoids rewrite churn). Returns true when the file was written.
    /// </summary>
    public bool Save(string exeDir)
    {
        var path = Path.Combine(exeDir, FileName);
        var json = JsonSerializer.Serialize(this, SaveOptions);
        if (File.Exists(path) && string.Equals(File.ReadAllText(path), json, StringComparison.Ordinal))
            return false;
        File.WriteAllText(path, json);
        return true;
    }
}
