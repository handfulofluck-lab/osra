using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Per-install parent PIN policy (ADR-0010, ADR-0037, W1b #1115). There is no default PIN: a PIN is
/// established at pairing, stored in <c>agent.config.json</c> only as a salted PBKDF2-HMAC-SHA256
/// hash (<c>pbkdf2$120000$&lt;saltB64&gt;$&lt;hashB64&gt;</c>, identical to Android <c>ParentPin.kt</c>
/// and <c>docs/test-vectors/parent-pin.tsv</c>), and lock / bedtime / screen-time refuse to arm
/// without a valid stored hash.
/// </summary>
internal static class ParentPinPolicy
{
    /// <summary>Env var read for the Debug-only one-time migration from pre-pairing-PIN installs.</summary>
    public const string EnvVar = "DESKTOP_PARENT_PIN";

    /// <summary>The old hard-coded default; never accepted as a configured PIN.</summary>
    public const string LegacyDefault = "0000";

    /// <summary>Shortest accepted PIN (inclusive).</summary>
    public const int MinLength = 4;

    /// <summary>Longest accepted PIN (inclusive).</summary>
    public const int MaxLength = 8;

    /// <summary>PBKDF2 iteration count matching Android <c>ParentPin.kt</c> and iOS <c>ParentPin.swift</c>.</summary>
    public const int Iterations = 120_000;

    /// <summary>Random salt size in bytes (128-bit).</summary>
    public const int SaltBytes = 16;

    /// <summary>Derived key size in bytes (256-bit).</summary>
    public const int KeyBytes = 32;

    /// <summary>Maximum iterations accepted during verification to prevent CPU DoS from tampered config.</summary>
    private const int MaxVerifyIterations = 10_000_000;

    private const string HashScheme = "pbkdf2";

    private static readonly HashSet<string> WeakPins = new(StringComparer.Ordinal)
    {
        "1234", "0000", "1111", "1212", "12345", "123456", "111111", "654321",
    };

    /// <summary>
    /// Maps Arabic-Indic (U+0660–U+0669) and Extended Arabic-Indic (U+06F0–U+06F9) digits to ASCII
    /// digits (#771). Every other character is unchanged.
    /// </summary>
    public static string NormalizeDigits(string value)
    {
        var chars = value.ToCharArray();
        for (var i = 0; i < chars.Length; i++)
        {
            var c = chars[i];
            if (c is >= '٠' and <= '٩') chars[i] = (char)('0' + (c - '٠'));
            else if (c is >= '۰' and <= '۹') chars[i] = (char)('0' + (c - '۰'));
        }
        return new string(chars);
    }

    /// <summary>True when <paramref name="pin"/> is 4–8 ASCII digits after <see cref="NormalizeDigits"/>.</summary>
    public static bool IsWellFormed(string? pin)
    {
        if (pin is null) return false;
        var digits = NormalizeDigits(pin);
        return digits.Length is >= MinLength and <= MaxLength && digits.All(char.IsAsciiDigit);
    }

    /// <summary>
    /// Validates a newly chosen PIN against the shared cross-platform rules in
    /// <c>docs/test-vectors/parent-pin.tsv</c>. Returns null when acceptable, else the exact
    /// refusal message shared with Android and iOS.
    /// </summary>
    public static string? Validate(string? pin)
    {
        var normalized = NormalizeDigits(pin ?? string.Empty);
        if (normalized.Length < MinLength) return $"PIN must be at least {MinLength} digits.";
        if (normalized.Length > MaxLength) return $"PIN must be at most {MaxLength} digits.";
        if (!normalized.All(char.IsAsciiDigit)) return "PIN must be digits only.";
        if (normalized.Distinct().Count() == 1) return "Choose a PIN that is not all the same digit.";
        if (WeakPins.Contains(normalized)) return "Choose a less predictable PIN.";
        return null;
    }

    /// <summary>
    /// Returns a normalized legacy plaintext PIN (4–8 digits, excluding legacy <c>0000</c>), or null.
    /// Used only for pairing input normalization and one-time migration of pre-W1b plaintext configs.
    /// </summary>
    public static string? Normalize(string? candidate)
    {
        var pin = candidate?.Trim();
        if (string.IsNullOrEmpty(pin)) return null;
        var digits = NormalizeDigits(pin);
        if (string.Equals(digits, LegacyDefault, StringComparison.Ordinal)) return null;
        return IsWellFormed(digits) ? digits : null;
    }

    /// <summary>
    /// Hashes <paramref name="pin"/> with a fresh 16-byte random salt into the Android/iOS-compatible
    /// <c>pbkdf2$120000$&lt;saltB64&gt;$&lt;hashB64&gt;</c> storage string.
    /// </summary>
    public static string Hash(string pin)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        return HashWithSalt(pin, salt, Iterations);
    }

    internal static string HashWithSalt(string pin, byte[] salt, int iterations = Iterations)
    {
        ArgumentNullException.ThrowIfNull(pin);
        ArgumentNullException.ThrowIfNull(salt);
        if (salt.Length == 0) throw new ArgumentException("Salt must not be empty.", nameof(salt));
        if (iterations <= 0) throw new ArgumentOutOfRangeException(nameof(iterations));

        var normalized = NormalizeDigits(pin);
        if (!IsWellFormed(normalized))
            throw new ArgumentException("PIN must be 4-8 digits.", nameof(pin));

        var derived = Pbkdf2(normalized, salt, iterations, KeyBytes);
        return $"{HashScheme}${iterations}${Convert.ToBase64String(salt)}${Convert.ToBase64String(derived)}";
    }

    /// <summary>
    /// True when <paramref name="candidate"/> is a structurally valid
    /// <c>pbkdf2$&lt;iterations&gt;$&lt;saltB64&gt;$&lt;hashB64&gt;</c> stored hash. Plaintext PINs
    /// and legacy <c>plain:</c> strings always return false.
    /// </summary>
    public static bool IsStoredHash(string? candidate) =>
        TryParseStoredHash(candidate, out _, out _, out _);

    /// <summary>
    /// Returns the trimmed stored hash when <paramref name="candidate"/> is a valid PBKDF2 hash,
    /// otherwise null. Plaintext PINs are never accepted as an active runtime configuration.
    /// </summary>
    public static string? NormalizeConfiguredHash(string? candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate)) return null;
        var trimmed = candidate.Trim();
        return IsStoredHash(trimmed) ? trimmed : null;
    }

    /// <summary>
    /// Converts a stored config value into a persisted PBKDF2 hash. Already-hashed values pass
    /// through unchanged (<paramref name="migrated"/> = false); valid legacy plaintext PINs are
    /// hashed immediately (<paramref name="migrated"/> = true); invalid values and legacy
    /// <c>0000</c> become null.
    /// </summary>
    public static string? MigrateToStoredHash(string? candidate, out bool migrated)
    {
        if (NormalizeConfiguredHash(candidate) is { } existingHash)
        {
            migrated = !string.Equals(candidate, existingHash, StringComparison.Ordinal);
            return existingHash;
        }

        if (Normalize(candidate) is { } legacyPlain)
        {
            migrated = true;
            return Hash(legacyPlain);
        }

        migrated = !string.IsNullOrEmpty(candidate);
        return null;
    }

    /// <summary>
    /// Resolves the stored PIN (preferring an already-stored hash or migrating a legacy plaintext
    /// value, then falling back to the Debug migration env var). Never returns plaintext.
    /// </summary>
    public static string? ResolveToStoredHash(string? stored, string? envPin, out bool changed)
    {
        var fromStored = MigrateToStoredHash(stored, out var migrated);
        if (fromStored is not null)
        {
            changed = migrated;
            return fromStored;
        }

        if (Normalize(envPin) is { } adopted)
        {
            changed = true;
            return Hash(adopted);
        }

        changed = migrated;
        return null;
    }

    /// <summary>
    /// Constant-time verification of <paramref name="entered"/> against a stored
    /// <c>pbkdf2$...</c> hash. Never throws on malformed input and never matches plaintext.
    /// </summary>
    public static bool Verify(string? entered, string? storedHash)
    {
        if (string.IsNullOrWhiteSpace(storedHash) || entered is null) return false;
        var normalized = NormalizeDigits(entered);
        // Reject out-of-range / non-digit inputs before running the KDF (osra-security#17 parity).
        if (!IsWellFormed(normalized)) return false;
        if (!TryParseStoredHash(storedHash.Trim(), out var iterations, out var salt, out var expected))
            return false;

        try
        {
            var actual = Pbkdf2(normalized, salt, iterations, expected.Length);
            return CryptographicOperations.FixedTimeEquals(expected, actual);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// True when <paramref name="entered"/> verifies against <paramref name="storedHash"/>.
    /// Rejects plaintext <paramref name="storedHash"/> values so no runtime path compares PINs in the clear.
    /// </summary>
    public static bool Matches(string? storedHash, string? entered) =>
        Verify(entered, storedHash);

    /// <summary>
    /// True when both entries are the same PIN in any accepted digit form. The pairing dialog uses it
    /// so a PIN chosen with an Arabic keyboard matches the repeat box typed either way (#771).
    /// </summary>
    public static bool SamePin(string? first, string? second)
    {
        var a = Normalize(first);
        var b = Normalize(second);
        return a is not null && string.Equals(a, b, StringComparison.Ordinal);
    }

    /// <summary>Generates a random 6-digit PIN that passes <see cref="Validate"/>.</summary>
    public static string Generate()
    {
        while (true)
        {
            var pin = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
            if (Validate(pin) is null) return pin;
        }
    }

    private static bool TryParseStoredHash(string? candidate, out int iterations, out byte[] salt, out byte[] hash)
    {
        iterations = 0;
        salt = [];
        hash = [];
        if (string.IsNullOrWhiteSpace(candidate)) return false;

        var parts = candidate.Trim().Split('$');
        if (parts.Length != 4 || !string.Equals(parts[0], HashScheme, StringComparison.Ordinal))
            return false;

        if (!int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out iterations) ||
            iterations <= 0 || iterations > MaxVerifyIterations)
            return false;

        try
        {
            salt = Convert.FromBase64String(parts[2]);
            hash = Convert.FromBase64String(parts[3]);
        }
        catch (FormatException)
        {
            return false;
        }

        return salt.Length > 0 && hash.Length > 0;
    }

    private static byte[] Pbkdf2(string normalizedPin, byte[] salt, int iterations, int keyBytes) =>
        Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(normalizedPin),
            salt,
            iterations,
            HashAlgorithmName.SHA256,
            keyBytes);
}
