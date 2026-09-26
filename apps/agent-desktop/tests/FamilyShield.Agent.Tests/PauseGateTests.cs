using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>Unit tests for <see cref="PauseGate"/> (Feature #11 pause sinkhole decision).</summary>
public sealed class PauseGateTests
{
    [Fact]
    public void BlocksEverythingWhenNoAllowlist()
    {
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("anything.example", null));
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("google.com", []));
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("api.backend.internal", null));
    }

    [Fact]
    public void AllowedDomainPassesThrough()
    {
        var allowed = new[] { "school.edu" };
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("school.edu", allowed));
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("www.school.edu", allowed));
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("deep.sub.school.edu", allowed));
    }

    [Fact]
    public void NonAllowedDomainIsBlockedEvenWhenAllowlistExists()
    {
        var allowed = new[] { "school.edu" };
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("youtube.com", allowed));
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("google.com", allowed)); // not emergency
    }

    [Fact]
    public void SuffixMatchRequiresALabelBoundary()
    {
        var allowed = new[] { "example.com" };
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("badexample.com", allowed));
        Assert.True(PauseGate.ShouldServeBlockPageWhenPaused("example.com.evil.org", allowed));
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("mail.example.com", allowed));
    }

    [Fact]
    public void MatchingIgnoresCaseAndTrailingDot()
    {
        var allowed = new[] { "School.EDU." };
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("WWW.SCHOOL.edu", allowed));
    }

    [Fact]
    public void EmptyHostIsNotBlockedHere()
    {
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("", new[] { "school.edu" }));
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused(null, new[] { "school.edu" }));
        Assert.False(PauseGate.ShouldServeBlockPageWhenPaused("   ", new[] { "school.edu" }));
    }
}
