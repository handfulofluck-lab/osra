using System.Security.Cryptography;
using System.Text;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Per-install parent PIN policy (desktop audit findings 1). There is no default PIN: a PIN is
/// established at pairing, kept in <c>agent.config.json</c> beside the device JWT / HMAC secret
/// (same file and permissions, no new crypto scheme), and lock / bedtime / screen-time refuse to
/// arm without one.
/// </summary>
/// <remarks>
/// Migration: an existing install that only has <c>DESKTOP_PARENT_PIN</c> set adopts that value
/// once into the config file; the legacy literal <c>0000</c> counts as unset, so an install that
/// relied on the old default must have a parent choose a real PIN.
/// </remarks>
internal static class ParentPinPolicy
{
    /// <summary>Env var read for the one-time migration from pre-pairing-PIN installs.</summary>
    public const string EnvVar = "DESKTOP_PARENT_PIN";

    /// <summary>The old hard-coded default; never accepted as a configured PIN.</summary>
    public const string LegacyDefault = "0000";

    /// <summary>Shortest accepted PIN (inclusive).</summary>
    public const int MinLength = 4;

    /// <summary>Longest accepted PIN (inclusive).</summary>
    public const int MaxLength = 8;

    /// <summary>True when <paramref name="pin"/> is 4–8 ASCII digits.</summary>
    public static bool IsWellFormed(string? pin) =>
        pin is not null &&
        pin.Length is >= MinLength and <= MaxLength &&
        pin.All(char.IsAsciiDigit);

    /// <summary>
    /// Returns the PIN that may be used, or null when none is configured. Blank values, malformed
    /// values and the legacy <c>0000</c> default are all "no PIN".
    /// </summary>
    public static string? Normalize(string? candidate)
    {
        var pin = candidate?.Trim();
        if (string.IsNullOrEmpty(pin)) return null;
        if (string.Equals(pin, LegacyDefault, StringComparison.Ordinal)) return null;
        return IsWellFormed(pin) ? pin : null;
    }

    /// <summary>
    /// The effective PIN: a valid stored PIN wins; otherwise <c>DESKTOP_PARENT_PIN</c> is adopted
    /// (migration), never when it is the legacy <c>0000</c>.
    /// </summary>
    public static string? Resolve(string? storedPin, string? envPin) =>
        Normalize(storedPin) ?? Normalize(envPin);

    /// <summary>
    /// True when <paramref name="entered"/> is the configured PIN. Uses a constant-time compare so
    /// the unlock box leaks no timing signal; a missing configured PIN never matches.
    /// </summary>
    public static bool Matches(string? configuredPin, string? entered)
    {
        var expected = Normalize(configuredPin);
        if (expected is null || entered is null) return false;
        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(entered));
    }

    /// <summary>Generates a random 6-digit PIN for the pair-and-show-once path.</summary>
    public static string Generate() =>
        RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
}
