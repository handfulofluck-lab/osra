using System.Security.Principal;
using System.Text.Json;

namespace FamilyShield.Agent.Services;

public interface IAccountIdentity
{
    string UserSid { get; }
    bool IsAdministrator { get; }
}

public sealed record RuntimeFacts(bool HasParentPin, bool TrayConnected, bool ProcessBlocking, bool WebFiltering);

internal sealed class WindowsAccountIdentity : IAccountIdentity
{
    public WindowsAccountIdentity()
    {
        using var identity = WindowsIdentity.GetCurrent();
        UserSid = identity.User!.Value;
        IsAdministrator = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    public string UserSid { get; }
    public bool IsAdministrator { get; }
}

public sealed class TrayConnectionState
{
    public bool IsConnected { get; set; }
}

public static class DesktopCapabilities
{
    public static JsonElement Create(IAccountIdentity user, RuntimeFacts facts)
    {
        var client = DesktopClientIdentity.CapabilityClient()
            ?? throw new InvalidDataException("The desktop build cannot be named truthfully.");
        var grants = new Dictionary<string, string>
        {
            ["child_account_admin"] = user.IsAdministrator ? "granted" : "missing",
        };
        var interactive = facts.HasParentPin && facts.TrayConnected ? "ready" : "unavailable";
        var features = new Dictionary<string, string>
        {
            ["lock_screen"] = interactive,
            ["pause_screen"] = interactive,
            ["app_blocking"] = facts.ProcessBlocking ? "ready" : "unavailable",
            ["screen_time"] = interactive,
            ["web_filter"] = facts.WebFiltering ? "degraded" : "unavailable",
            ["pause_internet"] = facts.WebFiltering ? "degraded" : "unavailable",
        };
        return JsonSerializer.SerializeToElement(new { client, grants, features, source = "tray" });
    }

    public static RuntimeFacts CurrentFacts(AgentConfig config, TrayConnectionState? state = null) => new(
        HasParentPin: ParentPinPolicy.Normalize(config.ParentPin) is not null,
        TrayConnected: state?.IsConnected == true,
        ProcessBlocking: true,
        WebFiltering: true);
}

public sealed class DesktopCapabilitiesStore
{
    private static readonly HashSet<string> FeatureKeys = new()
    {
        "lock_screen", "pause_screen", "app_blocking", "screen_time", "web_filter", "pause_internet",
    };

    private JsonElement? _current;

    public JsonElement? Current() => _current?.Clone();

    public void Update(JsonElement report)
    {
        if (report.ValueKind != JsonValueKind.Object ||
            report.EnumerateObject().Select(p => p.Name).ToHashSet() is not { Count: 4 } top ||
            !top.SetEquals(["client", "grants", "features", "source"])) throw new InvalidDataException("Invalid capability envelope.");
        if (report.GetProperty("source").GetString() != "tray")
            throw new InvalidDataException("Unexpected desktop report source.");
        if (report.GetProperty("client").GetProperty("app").GetString() != "agent-desktop")
            throw new InvalidDataException("Unexpected desktop client.");
        if (report.GetProperty("grants").EnumerateObject().Select(p => p.Name).SingleOrDefault() != "child_account_admin")
            throw new InvalidDataException("Unexpected grant vocabulary.");
        var admin = report.GetProperty("grants").GetProperty("child_account_admin").GetString();
        if (admin is not ("granted" or "missing")) throw new InvalidDataException("Unexpected grant state.");
        foreach (var feature in report.GetProperty("features").EnumerateObject())
        {
            if (!FeatureKeys.Contains(feature.Name) || feature.Value.GetString() is not ("ready" or "degraded" or "unavailable"))
                throw new InvalidDataException("Unexpected desktop feature state.");
        }
        _current = report.Clone();
    }
}

public sealed class DesktopCapabilitiesReporter : BackgroundService
{
    private static readonly TimeSpan ReportInterval = TimeSpan.FromMinutes(5);
    private readonly ITrayCommandSink _sink;
    private readonly AgentConfig _config;
    private readonly IAccountIdentity _account;
    private readonly TrayConnectionState? _state;
    private readonly ILogger<DesktopCapabilitiesReporter> _log;

    public DesktopCapabilitiesReporter(ITrayCommandSink sink, AgentConfig config, ILogger<DesktopCapabilitiesReporter> log,
        TrayConnectionState? state = null, IAccountIdentity? account = null)
    {
        _sink = sink;
        _config = config;
        _log = log;
        _state = state;
        _account = account ?? new WindowsAccountIdentity();
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await Report(stoppingToken);
        using var timer = new PeriodicTimer(ReportInterval);
        while (await timer.WaitForNextTickAsync(stoppingToken)) await Report(stoppingToken);
    }

    private async Task Report(CancellationToken cancellationToken)
    {
        try
        {
            var report = DesktopCapabilities.Create(_account, DesktopCapabilities.CurrentFacts(_config, _state));
            await _sink.SendAsync(new TrayMessage(TrayMessageKind.capabilities, report), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Could not report desktop capabilities");
        }
    }
}
