using System.Text.Json;
using System.Text.Json.Serialization;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Persistent agent identity (§14.3), stored as JSON beside the executable. The file is a source of
/// identity claims, not trusted endpoint, rule or enforcement configuration. Only Debug permits
/// environment overrides. A stored parent PIN remains local to the interactive tray until W1b.
/// </summary>
public sealed class AgentConfig
{
    /// <summary>Config file name, written next to the exe (AppContext.BaseDirectory).</summary>
    public const string FileName = "agent.config.json";

    /// <summary>The only API address a Release build may use.</summary>
    public const string ProductionApiBase = "https://api.osratech.com";

    /// <summary>Whether this loaded configuration may use legacy environment overrides.</summary>
    [JsonIgnore]
    public bool AllowEnvironmentOverrides { get; private set; }

    private static readonly JsonSerializerOptions LoadOptions = new(JsonSerializerDefaults.Web);
    private static readonly JsonSerializerOptions SaveOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    /// <summary>API address selected by the explicit Debug override or the compiled production constant.</summary>
    public string? ApiBase { get; set; }

    /// <summary>Device JWT issued by POST /v1/devices/pair/claim.</summary>
    public string? DeviceJwt { get; set; }

    /// <summary>This device's server-side id.</summary>
    public string? DeviceId { get; set; }

    /// <summary>The child this device enforces rules for.</summary>
    public string? ChildId { get; set; }

    /// <summary>Shared HMAC secret returned by pair/claim; signs /internal calls (alerts).</summary>
    public string? HmacSecret { get; set; }

    /// <summary>
    /// Per-install parent PIN, established at pairing and stored in this file for the tray. Lock,
    /// bedtime and screen-time refuse to arm while this is null. Debug-only
    /// <c>DESKTOP_PARENT_PIN</c> adoption preserves the legacy migration; W1b hashes this field.
    /// </summary>
    public string? ParentPin { get; set; }

    /// <summary>
    /// Whether the legacy WinINET proxy is configured. Release always enables it; a child-writable
    /// file cannot disable enforcement. Only Debug reads FS_SET_SYSTEM_PROXY.
    /// </summary>
    public bool SetSystemProxy { get; set; } = true;

    /// <summary>
    /// Reads identity claims from <paramref name="exeDir"/>/<see cref="FileName"/>. Endpoint and
    /// proxy configuration never come from that file. Environment overrides are considered only
    /// when <paramref name="allowEnvironmentOverrides"/> is explicitly true (the Debug host).
    /// Returns null for a corrupt file or when no device token is available.
    /// </summary>
    public static AgentConfig? Load(string exeDir, bool allowEnvironmentOverrides)
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
                return null;
            }
        }

        config ??= new AgentConfig();
        config.AllowEnvironmentOverrides = allowEnvironmentOverrides;
        config.ApiBase = ProductionApiBase;
        config.SetSystemProxy = true;
        if (!allowEnvironmentOverrides)
        {
            return string.IsNullOrWhiteSpace(config.DeviceJwt) ? null : config;
        }

        var fileHadIdentity = !string.IsNullOrWhiteSpace(config.DeviceJwt);
        config.ApiBase = Environment.GetEnvironmentVariable("API_BASE") ?? ProductionApiBase;
        config.DeviceJwt = Environment.GetEnvironmentVariable("DEVICE_JWT") ?? config.DeviceJwt;
        config.DeviceId = Environment.GetEnvironmentVariable("DEVICE_ID") ?? config.DeviceId;
        config.ChildId = Environment.GetEnvironmentVariable("CHILD_ID") ?? config.ChildId;
        config.HmacSecret = Environment.GetEnvironmentVariable("INTERNAL_HMAC_SECRET") ?? config.HmacSecret;

        // Legacy Debug migration: adopt the PIN once, never create an env-only identity file.
        var resolvedPin = ParentPinPolicy.Resolve(
            config.ParentPin, Environment.GetEnvironmentVariable(ParentPinPolicy.EnvVar));
        if (!string.Equals(config.ParentPin, resolvedPin, StringComparison.Ordinal))
        {
            config.ParentPin = resolvedPin;
            if (fileHadIdentity)
            {
                try
                {
                    config.Save(exeDir);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(
                        $"OSRA: could not persist the parent PIN to {Path.Combine(exeDir, FileName)}: {ex.Message}");
                }
            }
        }

        var setProxyEnv = Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY") ??
                          Environment.GetEnvironmentVariable("FS_SET_SYSTEM_PROXY", EnvironmentVariableTarget.User);
        if (!string.IsNullOrWhiteSpace(setProxyEnv))
        {
            config.SetSystemProxy = !string.Equals(setProxyEnv, "0", StringComparison.OrdinalIgnoreCase) &&
                                    !string.Equals(setProxyEnv, "false", StringComparison.OrdinalIgnoreCase);
        }

        return string.IsNullOrWhiteSpace(config.DeviceJwt) ? null : config;
    }

    /// <summary>
    /// Copies the identity claims once for the privileged service. PIN, rules and other UI or
    /// enforcement configuration are not carried across this boundary.
    /// </summary>
    public AgentConfig ForService() => new()
    {
        ApiBase = AllowEnvironmentOverrides ? ApiBase : ProductionApiBase,
        DeviceJwt = DeviceJwt,
        DeviceId = DeviceId,
        ChildId = ChildId,
        HmacSecret = HmacSecret,
        ParentPin = null,
        SetSystemProxy = AllowEnvironmentOverrides ? SetSystemProxy : true,
        AllowEnvironmentOverrides = AllowEnvironmentOverrides,
    };

    /// <summary>Copies only the paired identity claims, never endpoint, rule or PIN configuration.</summary>
    public void UpdateIdentityFrom(AgentConfig source)
    {
        DeviceJwt = source.DeviceJwt;
        DeviceId = source.DeviceId;
        ChildId = source.ChildId;
        HmacSecret = source.HmacSecret;
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
