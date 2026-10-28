using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FamilyShield.Agent.Services;

/// <summary>
/// First-run pairing (§14.1/§14.3): claims a parent-issued 6-digit code against
/// POST {apiBase}/v1/devices/pair/claim, waits for the parent to allow this PC, and produces the
/// persisted agent identity.
/// </summary>
public static class PairingService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>One poll every two seconds: the server's poll bucket is 60 a minute per address.</summary>
    internal static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    /// <summary>A code lives 600 s, so a claim cannot outlive it; this bounds the wait if the server never says.</summary>
    internal const int MaxPolls = 330;

    /// <summary>
    /// Claims <paramref name="code"/> at <paramref name="apiBase"/>, then waits for the parent's decision
    /// (plan 2.7: the parent approves each new device). The claim answers 202 with a claim id and a poll
    /// secret; <paramref name="onWaiting"/> runs then, and the device token arrives on the poll after the
    /// parent taps Allow, mapped to a new <see cref="AgentConfig"/> (not yet persisted).
    /// <paramref name="parentPin"/> is the per-install PIN the parent enters (or is shown once) at pairing;
    /// a claim without a well-formed PIN is rejected, because an agent with no PIN refuses to arm
    /// lock/bedtime/screen-time. Returns null when the code is unknown or the response is unusable;
    /// throws <see cref="PairingRefusedException"/> with a message for a code already in use, a Deny or
    /// an expiry; network errors on the claim propagate to the caller for message display.
    /// </summary>
    public static async Task<AgentConfig?> ClaimAsync(
        string apiBase,
        string code,
        string platform = "windows",
        string? parentPin = null,
        Action? onWaiting = null,
        CancellationToken ct = default,
        HttpMessageHandler? handler = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
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

        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.BaseAddress = baseUri;
        using var res = await http.PostAsJsonAsync("/v1/devices/pair/claim", new
        {
            code = code.Trim(),
            platform = string.IsNullOrWhiteSpace(platform) ? "windows" : platform.Trim(),
            model = Environment.MachineName,
            osVersion = Environment.OSVersion.VersionString,
        }, JsonOptions, ct);

        switch ((int)res.StatusCode)
        {
            case 202:
                break;
            case 409:
                throw new PairingRefusedException("This code is already being used by another device. Ask your parent for a new code.");
            case 428:
                throw new PairingRefusedException("Your parent needs to give consent in the OSRA app before this PC can be paired.");
            default:
                // NOTE: an unknown or expired code is 404 (invalid_or_expired_code); we don't parse the body.
                return null;
        }

        var ticket = await res.Content.ReadFromJsonAsync<ClaimTicket>(JsonOptions, ct);
        if (ticket is null || string.IsNullOrEmpty(ticket.ClaimId) || string.IsNullOrEmpty(ticket.PollSecret)) return null;
        onWaiting?.Invoke();

        var wait = delay ?? Task.Delay;
        for (var attempt = 0; attempt < MaxPolls; attempt++)
        {
            if (attempt > 0) await wait(PollInterval, ct);
            HttpResponseMessage poll;
            try
            {
                poll = await http.PostAsJsonAsync($"/v1/devices/pair/claims/{Uri.EscapeDataString(ticket.ClaimId)}/poll",
                    new { pollSecret = ticket.PollSecret }, JsonOptions, ct);
            }
            catch (HttpRequestException)
            {
                // A missed poll, not an answer: the parent may still be deciding.
                continue;
            }

            using (poll)
            {
                switch ((int)poll.StatusCode)
                {
                    case 202:
                        continue;
                    case 201:
                        return await ToConfig(poll, baseUrl, pin, ct);
                    case 410:
                        throw new PairingRefusedException("Your parent declined this PC. If that was a mistake, ask them for a new code.");
                    case 404:
                        throw new PairingRefusedException("The code expired before your parent allowed this PC. Ask them for a new code.");
                    case 428:
                        throw new PairingRefusedException("Your parent needs to give consent in the OSRA app before this PC can be paired.");
                    default:
                        return null;
                }
            }
        }

        throw new PairingRefusedException("The code expired before your parent allowed this PC. Ask them for a new code.");
    }

    private static async Task<AgentConfig?> ToConfig(HttpResponseMessage res, string baseUrl, string pin, CancellationToken ct)
    {
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

    /// <summary>The claim's 202 answer: what this PC polls with while the parent decides.</summary>
    private sealed class ClaimTicket
    {
        [JsonPropertyName("claimId")] public string? ClaimId { get; set; }

        [JsonPropertyName("pollSecret")] public string? PollSecret { get; set; }
    }

    /// <summary>The poll's 201 answer after Allow (the body the claim itself used to return).</summary>
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

/// <summary>A pairing that ended for a reason the person can act on; the message says what to do.</summary>
public sealed class PairingRefusedException(string message) : Exception(message);
