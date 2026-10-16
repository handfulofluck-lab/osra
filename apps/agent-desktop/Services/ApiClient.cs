using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace FamilyShield.Agent.Services;

/// <summary>Typed client for the FamilyShield backend API, authenticated with the device JWT.</summary>
// NOTE: unsealed with virtual POSTs so the tests can subclass a fake seam.
public class ApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly HttpClient _http;
    private readonly AgentConfig _config;

    /// <summary>
    /// Creates the client; attaches the Bearer token from <paramref name="config"/>.
    /// NOTE: env overrides are applied by <see cref="AgentConfig.Load"/>, not here.
    /// </summary>
    public ApiClient(HttpClient http, AgentConfig config)
    {
        _http = http;
        _config = config;
        if (!string.IsNullOrEmpty(config.DeviceJwt))
            _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", config.DeviceJwt);
    }

    /// <summary>POSTs a telemetry batch to /v1/devices/{deviceId}/telemetry; true on 2xx.</summary>
    internal virtual async Task<bool> PostTelemetry(string deviceId, TelemetryBatchDto payload, CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.PostAsJsonAsync(
                $"/v1/devices/{Uri.EscapeDataString(deviceId)}/telemetry", payload, JsonOptions, ct);
            return res.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>POSTs a persisted activity event batch to /v1/devices/{deviceId}/activity (#4); true on 2xx.</summary>
    internal virtual async Task<bool> PostActivityEvents(string deviceId, ActivityEventBatchDto batch, CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.PostAsJsonAsync(
                $"/v1/devices/{Uri.EscapeDataString(deviceId)}/activity", batch, JsonOptions, ct);
            return res.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>GETs the rule set for a child from /v1/rules/{childId}; null when unavailable.</summary>
    public async Task<RuleSetDto?> GetRules(string childId, CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.GetAsync($"/v1/rules/{Uri.EscapeDataString(childId)}", ct);
            if (!res.IsSuccessStatusCode) return null;
            return await res.Content.ReadFromJsonAsync<RuleSetDto>(JsonOptions, ct);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>GETs the blocklist pack from /v1/blocklists; null when unavailable (failures tolerated).</summary>
    public async Task<BlocklistPackDto?> GetBlocklists(CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.GetAsync("/v1/blocklists", ct);
            if (!res.IsSuccessStatusCode) return null;
            return await res.Content.ReadFromJsonAsync<BlocklistPackDto>(JsonOptions, ct);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>POSTs an alert to the HMAC-signed /v1/alerts/internal route; true on 2xx.</summary>
    public virtual async Task<bool> PostAlert(AlertDto alert, CancellationToken ct = default)
    {
        try
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(alert, JsonOptions);
            using var content = new ByteArrayContent(body);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            // The internal alert route requires the v2 signature headers (ADR-0014): timestamp +
            // nonce + HMAC over "ts.nonce.body". Signed with the paired per-device secret (BUG-001);
            // the INTERNAL_HMAC_SECRET env override is a dev-only fallback — the server will reject
            // it without a service caller header, by design.
            var secret = _config.HmacSecret ?? Environment.GetEnvironmentVariable("INTERNAL_HMAC_SECRET");
            if (!string.IsNullOrEmpty(secret))
            {
                var (signature, timestamp, nonce) = InternalSigner.Sign(secret, body);
                content.Headers.Add(InternalSigner.SignatureHeader, signature);
                content.Headers.Add(InternalSigner.TimestampHeader, timestamp);
                content.Headers.Add(InternalSigner.NonceHeader, nonce);
            }
            using var res = await _http.PostAsync("/v1/alerts/internal", content, ct);
            return res.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>GETs pending commands from /v1/devices/{deviceId}/commands; empty when unavailable.</summary>
    public async Task<IReadOnlyList<DeviceCommandDto>> GetCommands(string deviceId, CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.GetAsync($"/v1/devices/{Uri.EscapeDataString(deviceId)}/commands", ct);
            if (!res.IsSuccessStatusCode) return [];
            return await res.Content.ReadFromJsonAsync<List<DeviceCommandDto>>(JsonOptions, ct) ?? [];
        }
        catch (Exception)
        {
            return [];
        }
    }
}
