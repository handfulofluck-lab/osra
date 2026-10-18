using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FamilyShield.Agent.Services;

/// <summary>
/// First-run pairing (§14.1/§14.3): claims a parent-issued 6-digit code against
/// POST {apiBase}/v1/devices/pair/claim and produces the persisted agent identity.
/// </summary>
public static class PairingService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Claims <paramref name="code"/> at <paramref name="apiBase"/> and maps a 201 response to a new
    /// <see cref="AgentConfig"/> (not yet persisted). <paramref name="parentPin"/> is the per-install
    /// PIN the parent enters (or is shown once) at pairing; a claim without a well-formed PIN is
    /// rejected, because an agent with no PIN refuses to arm lock/bedtime/screen-time. Returns null
    /// when the request is rejected or the response is unusable; network errors propagate to the
    /// caller for message display.
    /// </summary>
    public static async Task<AgentConfig?> ClaimAsync(
        string apiBase,
        string code,
        string platform = "windows",
        string? parentPin = null,
        CancellationToken ct = default)
    {
        var baseUrl = (apiBase ?? string.Empty).Trim().TrimEnd('/');
        var pin = ParentPinPolicy.Normalize(parentPin);
        if (baseUrl.Length == 0 || string.IsNullOrWhiteSpace(code) || pin is null) return null;

        Uri baseUri;
        try
        {
            baseUri = new Uri(baseUrl);
        }
        catch (UriFormatException)
        {
            return null;
        }

        using var http = new HttpClient { BaseAddress = baseUri };
        using var res = await http.PostAsJsonAsync("/v1/devices/pair/claim", new
        {
            code = code.Trim(),
            platform = string.IsNullOrWhiteSpace(platform) ? "windows" : platform.Trim(),
            model = Environment.MachineName,
            osVersion = Environment.OSVersion.VersionString,
        }, JsonOptions, ct);

        // NOTE: rejected/expired codes surface as 404 (invalid_or_expired_code); we don't parse the body.
        if (res.StatusCode != HttpStatusCode.Created) return null;

        var payload = await res.Content.ReadFromJsonAsync<ClaimResponse>(JsonOptions, ct);
        if (payload is null || string.IsNullOrEmpty(payload.Token) ||
            string.IsNullOrEmpty(payload.DeviceId) || string.IsNullOrEmpty(payload.ChildId))
            return null;

        return new AgentConfig
        {
            ApiBase = baseUrl,
            DeviceJwt = payload.Token,
            DeviceId = payload.DeviceId,
            ChildId = payload.ChildId,
            HmacSecret = payload.HmacSecret,
            ParentPin = pin,
        };
    }

    /// <summary>Persists a paired config beside the exe; see <see cref="AgentConfig.Save"/>.</summary>
    public static bool Save(AgentConfig config) => config.Save(AppContext.BaseDirectory);

    private sealed class ClaimResponse
    {
        [JsonPropertyName("token")] public string? Token { get; set; }

        [JsonPropertyName("childId")] public string? ChildId { get; set; }

        /// <summary>Shared HMAC secret for signing /internal agent calls (BUG-001).</summary>
        [JsonPropertyName("hmacSecret")] public string? HmacSecret { get; set; }

        // NOTE: §14.1 returns { device, token, childId, familyId }; `device` is the created device row
        // (an object with `id`, matching POST /v1/devices/register). A bare JSON string is also accepted.
        [JsonPropertyName("device")] public JsonElement Device { get; set; }

        public string? DeviceId => Device.ValueKind switch
        {
            JsonValueKind.String => Device.GetString(),
            JsonValueKind.Object => Device.TryGetProperty("id", out var id) ? id.GetString() : null,
            _ => null,
        };
    }
}
