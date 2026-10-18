using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Tests for <see cref="ParentPinPolicy"/> (desktop audit finding 1): no default PIN, the legacy
/// <c>0000</c> is never adopted, a stored PIN wins over the migration env var, and the overlay
/// refuses to show without a real PIN.
/// </summary>
public sealed class ParentPinPolicyTests
{
    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData("   ", false)]
    [InlineData("0000", true)] // format-valid; the legacy default is rejected by Normalize, not here
    [InlineData("123", false)]
    [InlineData("1234", true)]
    [InlineData("12345678", true)]
    [InlineData("123456789", false)]
    [InlineData("12 34", false)]
    [InlineData("abcd", false)]
    public void WellFormedIsFourToEightAsciiDigits(string? pin, bool expected) =>
        Assert.Equal(expected, ParentPinPolicy.IsWellFormed(pin));

    [Fact]
    public void LegacyDefaultIsNeverAConfiguredPin()
    {
        Assert.Null(ParentPinPolicy.Normalize(ParentPinPolicy.LegacyDefault));
        Assert.False(ParentPinPolicy.Matches(ParentPinPolicy.LegacyDefault, ParentPinPolicy.LegacyDefault));
    }

    [Fact]
    public void ResolvePrefersTheStoredPinOverTheMigrationEnvVar()
    {
        Assert.Equal("4821", ParentPinPolicy.Resolve("4821", "9999"));
    }

    [Fact]
    public void ResolveAdoptsAValidEnvPinWhenNothingIsStored()
    {
        Assert.Equal("4821", ParentPinPolicy.Resolve(null, "4821"));
    }

    [Fact]
    public void ResolveDoesNotAdoptTheLegacyDefaultFromEnv()
    {
        Assert.Null(ParentPinPolicy.Resolve(null, ParentPinPolicy.LegacyDefault));
        Assert.Equal("4821", ParentPinPolicy.Resolve(ParentPinPolicy.LegacyDefault, "4821"));
    }

    [Fact]
    public void MatchesAcceptsOnlyTheConfiguredPin()
    {
        Assert.True(ParentPinPolicy.Matches("4821", "4821"));
        Assert.False(ParentPinPolicy.Matches("4821", "4820"));
        Assert.False(ParentPinPolicy.Matches("4821", "4821 "));
        Assert.False(ParentPinPolicy.Matches("4821", ""));
        Assert.False(ParentPinPolicy.Matches("4821", null));
        Assert.False(ParentPinPolicy.Matches(null, "4821"));
    }

    [Fact]
    public void GeneratedPinIsSixDigitsAndWellFormed()
    {
        for (var i = 0; i < 100; i++)
        {
            var pin = ParentPinPolicy.Generate();
            Assert.Equal(6, pin.Length);
            Assert.True(ParentPinPolicy.IsWellFormed(pin));
            Assert.Equal(pin, ParentPinPolicy.Normalize(pin));
        }
    }

    [Fact]
    public void LockOverlayRefusesToShowWithoutAValidPin()
    {
        // These return before the WinForms message loop starts, so no UI thread is created.
        Assert.False(LockOverlay.ShowIfPinned(null!, "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("", "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("0000", "OSRA", "message"));
        Assert.False(LockOverlay.ShowIfPinned("12", "OSRA", "message"));
    }
}
