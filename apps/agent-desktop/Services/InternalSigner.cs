using System.Security.Cryptography;
using System.Text;

namespace FamilyShield.Agent.Services;

/// <summary>
/// v2 internal request signing (ADR-0014): the three headers the API verifies on every
/// <c>/internal</c> call. The signature is HMAC-SHA256 over <c>"&lt;timestamp&gt;.&lt;nonce&gt;."</c> followed by
/// the exact body bytes; the server rejects a timestamp more than 5 minutes off its clock and any
/// nonce it has already seen for this device, so a captured request cannot be replayed.
/// </summary>
public static class InternalSigner
{
    public const string SignatureHeader = "X-FamilyShield-Signature";
    public const string TimestampHeader = "X-FamilyShield-Timestamp";
    public const string NonceHeader = "X-FamilyShield-Nonce";

    /// <summary>The v2 signing string: timestamp, nonce and body, dot-joined, byte for byte.</summary>
    public static byte[] SigningBytes(string timestamp, string nonce, byte[] body)
    {
        var prefix = Encoding.UTF8.GetBytes($"{timestamp}.{nonce}.");
        var all = new byte[prefix.Length + body.Length];
        Buffer.BlockCopy(prefix, 0, all, 0, prefix.Length);
        Buffer.BlockCopy(body, 0, all, prefix.Length, body.Length);
        return all;
    }

    /// <summary>Lowercase hex HMAC-SHA256 of <paramref name="data"/> under <paramref name="secret"/>.</summary>
    public static string HmacHex(string secret, byte[] data)
    {
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret));
        return Convert.ToHexString(hmac.ComputeHash(data)).ToLowerInvariant();
    }

    /// <summary>16 random bytes as 32 lowercase hex characters.</summary>
    public static string NewNonce() => Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();

    /// <summary>Returns the three v2 headers for <paramref name="body"/>.</summary>
    public static (string Signature, string Timestamp, string Nonce) Sign(string secret, byte[] body, long? unixSeconds = null, string? nonce = null)
    {
        var ts = (unixSeconds ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds()).ToString();
        var n = nonce ?? NewNonce();
        return (HmacHex(secret, SigningBytes(ts, n, body)), ts, n);
    }
}
