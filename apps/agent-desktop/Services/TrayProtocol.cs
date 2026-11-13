using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FamilyShield.Agent.Services;

public enum TrayDirection
{
    ToTray,
    ToService,
}

public enum TrayMessageKind
{
    hello,
    rules,
    @lock,
    unlock,
    pause,
    resume,
    ring,
    wind_down,
    pairing_reset,
    pairing_complete,
    foreground_sample,
    sos,
    capabilities,
}

public sealed record TrayMessage(TrayMessageKind Kind, JsonElement? Payload = null);

public static class TrayPipeName
{
    public static string ForSession(int sessionId)
    {
        if (sessionId <= 0) throw new ArgumentOutOfRangeException(nameof(sessionId));
        return $"osra-tray-{sessionId.ToString(CultureInfo.InvariantCulture)}";
    }
}

public static class TrayProtocol
{
    public const int MaxFrameBytes = 65_536;
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(15);

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter<TrayMessageKind>() },
    };

    // The complete server rule set must survive for LocalRuleStore, including fields the desktop
    // does not enforce. Its known fields are still validated; the message envelope stays strict.
    private static readonly JsonSerializerOptions RulePayloadOptions = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    };

    public static async Task WriteAsync(Stream stream, TrayMessage message, TrayDirection destination,
        CancellationToken cancellationToken = default)
    {
        RequireDirection(message.Kind, destination);
        ValidatePayload(message);
        var body = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        if (body.Length > MaxFrameBytes) throw new InvalidDataException("Tray frame exceeds the size bound.");
        await stream.WriteAsync(BitConverter.GetBytes(body.Length), cancellationToken);
        await stream.WriteAsync(body, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    public static async Task<TrayMessage> ReadAsync(Stream stream, TrayDirection destination,
        TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout ?? ReadTimeout);
        var prefix = new byte[4];
        await stream.ReadExactlyAsync(prefix, timeoutSource.Token);
        var length = BitConverter.ToInt32(prefix);
        if (length <= 0 || length > MaxFrameBytes) throw new InvalidDataException("Invalid tray frame length.");
        var body = new byte[length];
        await stream.ReadExactlyAsync(body, timeoutSource.Token);
        var message = JsonSerializer.Deserialize<TrayMessage>(body, JsonOptions)
            ?? throw new InvalidDataException("Empty tray message.");
        RequireDirection(message.Kind, destination);
        ValidatePayload(message);
        return message;
    }

    private static void RequireDirection(TrayMessageKind kind, TrayDirection destination)
    {
        var valid = destination == TrayDirection.ToTray
            ? kind is TrayMessageKind.rules or TrayMessageKind.@lock or TrayMessageKind.unlock or TrayMessageKind.pause
                or TrayMessageKind.resume or TrayMessageKind.ring or TrayMessageKind.wind_down or TrayMessageKind.pairing_reset
            : kind is TrayMessageKind.hello or TrayMessageKind.pairing_complete or TrayMessageKind.foreground_sample
                or TrayMessageKind.sos or TrayMessageKind.capabilities;
        if (!valid) throw new UnauthorizedAccessException("Tray message is not allowed in this direction.");
    }

    private static void ValidatePayload(TrayMessage message)
    {
        var kind = message.Kind;
        if (message.Payload is not { } payload || payload.ValueKind == JsonValueKind.Null)
        {
            if (kind is TrayMessageKind.hello or TrayMessageKind.@lock or TrayMessageKind.unlock or TrayMessageKind.pause
                or TrayMessageKind.resume or TrayMessageKind.ring or TrayMessageKind.pairing_reset
                or TrayMessageKind.pairing_complete or TrayMessageKind.sos) return;
            throw new InvalidDataException("Tray message requires a payload.");
        }

        switch (kind)
        {
            case TrayMessageKind.wind_down:
                var windDown = payload.Deserialize<WindDownPayload>(JsonOptions)
                    ?? throw new InvalidDataException("Invalid wind-down payload.");
                if (windDown.Minutes is < 1 or > 1440) throw new InvalidDataException("Wind-down is outside the allowed range.");
                break;
            case TrayMessageKind.foreground_sample:
                var sample = payload.Deserialize<ForegroundSamplePayload>(JsonOptions)
                    ?? throw new InvalidDataException("Invalid foreground sample.");
                if (string.IsNullOrWhiteSpace(sample.ProcessName) || sample.ProcessName.Trim().Length > 260)
                    throw new InvalidDataException("Invalid foreground process name.");
                break;
            case TrayMessageKind.rules:
                _ = payload.Deserialize<RuleSetDto>(RulePayloadOptions)
                    ?? throw new InvalidDataException("Invalid rule set.");
                RefuseCredentials(payload);
                break;
            case TrayMessageKind.capabilities:
                if (payload.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid capabilities report.");
                RefuseCredentials(payload);
                break;
            default:
                throw new InvalidDataException("This tray command does not accept a payload.");
        }
    }

    private static void RefuseCredentials(JsonElement payload)
    {
        if (payload.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in payload.EnumerateObject())
            {
                var name = property.Name.ToLowerInvariant();
                if (name.EndsWith("token") || name.EndsWith("secret") || name.EndsWith("jwt") ||
                    name.EndsWith("pin") || name is "password" or "authorization" or "apikey" or "privatekey")
                {
                    throw new InvalidDataException("Credential fields are not allowed on the tray pipe.");
                }
                RefuseCredentials(property.Value);
            }
        }
        else if (payload.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in payload.EnumerateArray()) RefuseCredentials(item);
        }
    }

    private sealed class WindDownPayload
    {
        public int Minutes { get; set; }
    }

    private sealed class ForegroundSamplePayload
    {
        public string? ProcessName { get; set; }
    }
}
