using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Feature #9: while the internet is paused every user process NOT in alwaysAllowedApps is
/// killed; always-allowed apps (and everything when not paused) survive.
/// </summary>
public sealed class ProcessMonitorPauseTests
{
    public static IEnumerable<object?[]> Matrix()
    {
        yield return ["minecraft", new[] { "chrome" }, true, true]; // paused + not allowed -> kill
        yield return ["chrome", new[] { "chrome" }, true, false]; // paused + allowed -> keep
        yield return ["minecraft", new[] { "chrome" }, false, false]; // not paused -> keep
        yield return ["chrome", new[] { "chrome" }, false, false]; // not paused -> keep
    }

    [Theory]
    [MemberData(nameof(Matrix))]
    public void ShouldKillWhenPausedCoversTheFullMatrix(string process, string[] allowed, bool paused, bool expected)
    {
        Assert.Equal(expected, ProcessMonitor.ShouldKillWhenPaused(process, allowed, paused));
    }

    [Theory]
    // Names are normalized both sides (".exe" stripped, case-insensitive) before matching.
    [InlineData("Notepad.exe", "notepad", true, false)]
    [InlineData("NOTEPAD", "notepad.exe", true, false)]
    [InlineData("chrome.exe", "chrome", true, false)]
    [InlineData("Minecraft.Windows.exe", "minecraft.windows", true, false)]
    [InlineData("Notepad.exe", "notepad", false, false)] // not paused wins even when not allowed
    [InlineData("", "chrome", true, false)] // empty names are never killed
    [InlineData("   ", "chrome", true, false)]
    public void ShouldKillWhenPausedNormalizesProcessNames(string process, string allowed, bool paused, bool expected)
    {
        Assert.Equal(expected, ProcessMonitor.ShouldKillWhenPaused(process, new[] { allowed }, paused));
    }

    [Fact]
    public void NotAllowedAppsAreKilledAcrossCases()
    {
        Assert.True(ProcessMonitor.ShouldKillWhenPaused("DISCORD", new[] { "chrome" }, paused: true));
        Assert.True(ProcessMonitor.ShouldKillWhenPaused("discord.exe", new[] { "chrome" }, paused: true));
    }

    [Fact]
    public void MatchesRuleMatchesCurrentProcessByName()
    {
        using var current = System.Diagnostics.Process.GetCurrentProcess();
        Assert.True(ProcessMonitor.MatchesRule(current, current.ProcessName));
        Assert.True(ProcessMonitor.MatchesRule(current, current.ProcessName.ToUpperInvariant()));
        Assert.False(ProcessMonitor.MatchesRule(current, "definitely_not_running_app_xyz"));
    }
}
