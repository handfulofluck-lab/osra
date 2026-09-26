namespace FamilyShield.Agent.Services;

/// <summary>Uploads buffered URL log and app usage rows every 5 minutes.</summary>
public sealed class TelemetryUploader : BackgroundService
{
    private static readonly TimeSpan UploadInterval = TimeSpan.FromMinutes(5);

    private readonly ILogger<TelemetryUploader> _log;
    private readonly LocalRuleStore _store;
    private readonly ApiClient _api;
    private readonly AgentConfig _config;

    /// <summary>Creates the uploader.</summary>
    public TelemetryUploader(ILogger<TelemetryUploader> log, LocalRuleStore store, ApiClient api, AgentConfig config)
    {
        _log = log;
        _store = store;
        _api = api;
        _config = config;
    }

    /// <summary>Uploads batches until the worker stops; failures are logged and retried next cycle.</summary>
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(UploadInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try
                {
                    await UploadOnce(stoppingToken);
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "TelemetryUploader tick failed");
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    internal async Task UploadOnce(CancellationToken ct)
    {
        var deviceId = _config.DeviceId;
        if (string.IsNullOrEmpty(deviceId))
        {
            _log.LogWarning("DeviceId not configured; skipping telemetry upload");
            return;
        }

        var batch = _store.GetUnuploadedTelemetry();
        batch.BatteryPct = BatteryStatus.GetBatteryPercent();
        // Always POST: even with no buffered rows the battery field is the
        // device heartbeat that keeps lastSeen/battery fresh server-side.
        if (!await _api.PostTelemetry(deviceId, batch, ct))
        {
            _log.LogWarning("Telemetry POST not accepted; rows stay buffered for the next cycle");
            return;
        }

        // Feature #4: the same buffered rows are persisted as ActivityEvents for reports.
        // NOTE ordering: url_log rows are marked uploaded only after BOTH posts succeed, so
        // the events derived from them are durably stored first; on an activity failure the
        // rows stay buffered and are re-derived (idempotent createMany) next cycle.
        var events = ActivityEventMapper.FromBatch(batch);
        if (events.Count > 0 && !await _api.PostActivityEvents(deviceId, new ActivityEventBatchDto { Events = events }, ct))
        {
            _log.LogWarning("Activity POST not accepted; url_log/app_usage rows stay buffered for the next cycle");
            return;
        }

        _store.MarkTelemetryUploaded(batch.UrlLogCursor);
        _log.LogInformation("Uploaded telemetry: {Urls} urls, {Apps} app-usage rows, {Events} activity events, battery {Battery}%",
            batch.Urls.Count, batch.AppUsage.Count, events.Count, batch.BatteryPct);
    }
}

/// <summary>Maps buffered url_log/app_usage rows to persisted ActivityEvents (Feature #4).</summary>
public static class ActivityEventMapper
{
    /// <summary>Builds the activity batch from a telemetry batch: url events carry {domain, blocked}, app_usage events {app, minutes}.</summary>
    public static List<ActivityEventDto> FromBatch(TelemetryBatchDto batch)
    {
        var events = new List<ActivityEventDto>();
        foreach (var url in batch.Urls)
        {
            events.Add(new ActivityEventDto
            {
                Ts = url.Ts,
                Type = "url",
                Payload = new Dictionary<string, object> { ["domain"] = url.Host, ["blocked"] = url.Blocked },
            });
        }
        foreach (var app in batch.AppUsage)
        {
            events.Add(new ActivityEventDto
            {
                Type = "app_usage",
                Payload = new Dictionary<string, object> { ["app"] = app.Process, ["minutes"] = app.Minutes },
            });
        }
        return events;
    }
}

/// <summary>Reads the Windows system battery state (100% when there is no battery, e.g. desktops).</summary>
internal static class BatteryStatus
{
    private const byte NoBattery = 255;

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool GetSystemPowerStatus(ref SYSTEM_POWER_STATUS status);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte Reserved1;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    /// <summary>Returns the current battery percentage, or 100 when the machine has no battery.</summary>
    public static int GetBatteryPercent()
    {
        var status = new SYSTEM_POWER_STATUS();
        if (!GetSystemPowerStatus(ref status)) return 100;
        return status.BatteryLifePercent == NoBattery ? 100 : status.BatteryLifePercent;
    }
}
