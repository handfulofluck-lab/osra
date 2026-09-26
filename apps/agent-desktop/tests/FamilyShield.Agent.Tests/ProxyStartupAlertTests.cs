using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>Unit tests for <see cref="ProxyStartupAlert"/> (review #26 fail-open startup alert).</summary>
public sealed class ProxyStartupAlertTests
{
    private static readonly DateTime Now = new(2026, 9, 18, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void AlertsWhenProxyFailedAndPairedAndThrottleElapsed()
    {
        var lastAlert = Now - ProxyStartupAlert.Throttle;
        Assert.True(ProxyStartupAlert.ShouldAlertProxyFailed(lastAlert, Now, running: false, paired: true));
    }

    [Fact]
    public void AlertsOnFirstFailureWithNoPriorAlert()
    {
        Assert.True(ProxyStartupAlert.ShouldAlertProxyFailed(DateTime.MinValue, Now, running: false, paired: true));
    }

    [Fact]
    public void NoAlertWhileProxyIsRunning()
    {
        var lastAlert = Now - TimeSpan.FromDays(1);
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(lastAlert, Now, running: true, paired: true));
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(DateTime.MinValue, Now, running: true, paired: true));
    }

    [Fact]
    public void NoAlertWhenUnpaired()
    {
        var lastAlert = Now - TimeSpan.FromDays(1);
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(lastAlert, Now, running: false, paired: false));
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(DateTime.MinValue, Now, running: false, paired: false));
    }

    [Fact]
    public void NoAlertInsideThrottleWindow()
    {
        var lastAlert = Now - ProxyStartupAlert.Throttle + TimeSpan.FromSeconds(1);
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(lastAlert, Now, running: false, paired: true));

        var justAlerted = Now - TimeSpan.FromMinutes(5);
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(justAlerted, Now, running: false, paired: true));
    }

    [Fact]
    public void ThrottleBoundaryIsInclusive()
    {
        var lastAlert = Now - ProxyStartupAlert.Throttle - TimeSpan.FromTicks(1);
        Assert.True(ProxyStartupAlert.ShouldAlertProxyFailed(lastAlert, Now, running: false, paired: true));
    }

    [Fact]
    public void RunningAndUnpairedNeverAlertRegardlessOfThrottle()
    {
        Assert.False(ProxyStartupAlert.ShouldAlertProxyFailed(DateTime.MinValue, Now, running: true, paired: false));
    }
}
