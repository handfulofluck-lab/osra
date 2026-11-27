using System.Runtime.CompilerServices;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Tests for <see cref="ParentPinPolicy"/> (ADR-0010, ADR-0037, W1b #1115): cross-platform
/// <c>docs/test-vectors/parent-pin.tsv</c> parity, salted PBKDF2-HMAC-SHA256 hashing, constant-time
/// verification, plaintext refusal, and overlay arming guard.
/// </summary>
public sealed class ParentPinPolicyTests
{
    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData("   ", false)]
    [InlineData("0000", true)] // format-valid; the legacy default is rejected by Validate/Normalize, not here
    [InlineData("123", false)]
    [InlineData("1234", true)]
    [InlineData("12345678", true)]
    [InlineData("123456789", false)]
    [InlineData("12 34", false)]
    [InlineData("abcd", false)]
    [InlineData("١٢٣٤", true)]
    [InlineData("۱۲۳۴", true)]
    [InlineData("١٢٣", false)]
    [InlineData("١٢٣٤٥٦٧٨٩", false)]
    public void WellFormedIsFourToEightAsciiDigits(string? pin, bool expected) =>
        Assert.Equal(expected, ParentPinPolicy.IsWellFormed(pin));

    [Fact]
    public void SharedCrossPlatformTestVectorsPass()
    {
        var path = SharedVectorsPath();
        Assert.True(File.Exists(path), $"Shared parent-pin vector file missing at {path}");

        var validateCases = 0;
        var verifyCases = 0;
        foreach (var rawLine in File.ReadAllLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var parts = line.Split('\t');
            switch (parts[0])
            {
                case "validate":
                    Assert.Equal(3, parts.Length);
                    var pin = UnescapeEmpty(parts[1]);
                    var expectedMessage = parts[2] == "ok" ? null : parts[2];
                    Assert.Equal(expectedMessage, ParentPinPolicy.Validate(pin));
                    validateCases++;
                    break;
                case "verify":
                    Assert.Equal(4, parts.Length);
                    var candidate = UnescapeEmpty(parts[1]);
                    var stored = UnescapeEmpty(parts[2]);
                    var expectedMatch = bool.Parse(parts[3]);
                    Assert.Equal(expectedMatch, ParentPinPolicy.Verify(candidate, stored));
                    Assert.Equal(expectedMatch, ParentPinPolicy.Matches(stored, candidate));
                    verifyCases++;
                    break;
                default:
                    Assert.Fail($"Unexpected vector directive: {parts[0]}");
                    break;
            }
        }

        Assert.True(validateCases >= 15, $"Expected at least 15 validate vectors, saw {validateCases}");
        Assert.True(verifyCases >= 10, $"Expected at least 10 verify vectors, saw {verifyCases}");
    }

    [Fact]
    public void HashUsesAndroidCompatiblePbkdf2FormatWithUniqueRandomSalts()
    {
        var first = ParentPinPolicy.Hash("4729");
        var second = ParentPinPolicy.Hash("4729");

        Assert.StartsWith("pbkdf2$120000$", first, StringComparison.Ordinal);
        Assert.StartsWith("pbkdf2$120000$", second, StringComparison.Ordinal);
        Assert.NotEqual(first, second);
        Assert.DoesNotContain("4729", first, StringComparison.Ordinal);
        Assert.True(ParentPinPolicy.IsStoredHash(first));
        Assert.True(ParentPinPolicy.Verify("4729", first));
        Assert.True(ParentPinPolicy.Verify("4729", second));
        Assert.False(ParentPinPolicy.Verify("4728", first));
    }

    [Fact]
    public void LegacyDefaultIsNeverAConfiguredPin()
    {
        Assert.Null(ParentPinPolicy.Normalize(ParentPinPolicy.LegacyDefault));
        Assert.NotNull(ParentPinPolicy.Validate(ParentPinPolicy.LegacyDefault));
        Assert.False(ParentPinPolicy.Matches(ParentPinPolicy.LegacyDefault, ParentPinPolicy.LegacyDefault));
    }

    [Theory]
    [InlineData("1٢3۴", "1234")]
    [InlineData("1ب2", "1ب2")]
    [InlineData("٠٠٠٠", "0000")]
    [InlineData("۰۱۲", "012")]
    public void NormalizeDigitsMapsBothFamiliesAndLeavesTheRest(string input, string expected) =>
        Assert.Equal(expected, ParentPinPolicy.NormalizeDigits(input));

    [Fact]
    public void ArabicDigitsHashAndVerifyIdenticallyToAsciiDigits()
    {
        Assert.Equal("4729", ParentPinPolicy.Normalize("٤٧٢٩"));
        var hashFromAscii = ParentPinPolicy.Hash("4729");
        var hashFromArabic = ParentPinPolicy.Hash("٤٧٢٩");

        Assert.True(ParentPinPolicy.Matches(hashFromAscii, "٤٧٢٩"));
        Assert.True(ParentPinPolicy.Matches(hashFromAscii, "۴۷۲۹"));
        Assert.True(ParentPinPolicy.Matches(hashFromArabic, "4729"));
        Assert.True(ParentPinPolicy.Matches(hashFromArabic, "۴۷۲۹"));
    }

    [Fact]
    public void TheConfirmBoxMatchesInEitherDigitForm()
    {
        Assert.True(ParentPinPolicy.SamePin("4729", "٤٧٢٩"));
        Assert.True(ParentPinPolicy.SamePin("٤٧٢٩", "4729"));
        Assert.False(ParentPinPolicy.SamePin("4729", "4728"));
        Assert.False(ParentPinPolicy.SamePin("4729", null));
    }

    [Fact]
    public void TheLegacyDefaultIsRefusedInEitherDigitForm()
    {
        Assert.Null(ParentPinPolicy.Normalize("٠٠٠٠"));
        Assert.Null(ParentPinPolicy.Normalize("۰۰۰۰"));
        Assert.NotNull(ParentPinPolicy.Validate("٠٠٠٠"));
        Assert.NotNull(ParentPinPolicy.Validate("۰۰۰۰"));
    }

    [Fact]
    public void ResolveToStoredHashPrefersStoredHashOrMigratesLegacyPlaintextOverEnvVar()
    {
        var existingHash = ParentPinPolicy.Hash("4821");
        var kept = ParentPinPolicy.ResolveToStoredHash(existingHash, "9381", out var changedKept);
        Assert.Equal(existingHash, kept);
        Assert.False(changedKept);

        var migrated = ParentPinPolicy.ResolveToStoredHash("4821", "9381", out var changedMigrated);
        Assert.True(changedMigrated);
        Assert.True(ParentPinPolicy.IsStoredHash(migrated));
        Assert.True(ParentPinPolicy.Matches(migrated, "4821"));
        Assert.False(ParentPinPolicy.Matches(migrated, "9381"));
    }

    [Fact]
    public void ResolveToStoredHashAdoptsValidEnvPinAsHashWhenNothingIsStored()
    {
        var adopted = ParentPinPolicy.ResolveToStoredHash(null, "4821", out var changed);
        Assert.True(changed);
        Assert.True(ParentPinPolicy.IsStoredHash(adopted));
        Assert.True(ParentPinPolicy.Matches(adopted, "4821"));
    }

    [Fact]
    public void ResolveToStoredHashDoesNotAdoptLegacyDefaultFromEnv()
    {
        Assert.Null(ParentPinPolicy.ResolveToStoredHash(null, ParentPinPolicy.LegacyDefault, out var changedNull));
        Assert.False(changedNull);

        var adopted = ParentPinPolicy.ResolveToStoredHash(ParentPinPolicy.LegacyDefault, "4821", out var changed);
        Assert.True(changed);
        Assert.True(ParentPinPolicy.Matches(adopted, "4821"));
    }

    [Fact]
    public void MatchesAcceptsOnlyStoredHashesAndRefusesPlaintext()
    {
        var hash = ParentPinPolicy.Hash("4821");
        Assert.True(ParentPinPolicy.Matches(hash, "4821"));
        Assert.False(ParentPinPolicy.Matches(hash, "4820"));
        Assert.False(ParentPinPolicy.Matches(hash, "4821 "));
        Assert.False(ParentPinPolicy.Matches(hash, ""));
        Assert.False(ParentPinPolicy.Matches(hash, null));
        Assert.False(ParentPinPolicy.Matches(null, "4821"));
        // Plaintext stored values must never match.
        Assert.False(ParentPinPolicy.Matches("4821", "4821"));
        Assert.False(ParentPinPolicy.Matches("plain:4821", "4821"));
    }

    [Fact]
    public void GeneratedPinIsSixDigitsAndPassesSharedValidation()
    {
        for (var i = 0; i < 100; i++)
        {
            var pin = ParentPinPolicy.Generate();
            Assert.Equal(6, pin.Length);
            Assert.True(ParentPinPolicy.IsWellFormed(pin));
            Assert.Null(ParentPinPolicy.Validate(pin));
        }
    }

    [Fact]
    public void LockOverlayRefusesToShowWithoutAValidStoredHash()
    {
        // These return before the WinForms message loop starts, so no UI thread is created.
        Assert.False(LockOverlay.ShowIfPinned(null!, "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("", "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("0000", "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("12", "OSRA", "message"));
        // Plaintext PINs must also be refused by the overlay (W1b #1115).
        Assert.False(LockOverlay.ShowIfPinned("4821", "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("plain:4821", "OSRA", "message"));
    }

    private static string UnescapeEmpty(string token) => token == "<empty>" ? string.Empty : token;

    private static string SharedVectorsPath([CallerFilePath] string sourceFile = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(sourceFile)!, "..", "..", "..", "..", "docs", "test-vectors", "parent-pin.tsv"));
}
