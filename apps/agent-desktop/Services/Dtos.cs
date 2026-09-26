using System.Text.Json;
using System.Text.Json.Serialization;

namespace FamilyShield.Agent.Services;

/// <summary>Wire shape of the screen-time portion of a RuleSet (see packages/shared-types §2).</summary>
public sealed class ScreenTimeRuleDto
{
    /// <summary>Daily screen-time budget in minutes.</summary>
    [JsonPropertyName("dailyLimitMinutes")] public int DailyLimitMinutes { get; set; }

    /// <summary>Weekend budget in minutes; null/0 means "same as daily".</summary>
    [JsonPropertyName("weekendLimitMinutes")] public int? WeekendLimitMinutes { get; set; }

    /// <summary>Bedtime start as "HH:mm" local time.</summary>
    [JsonPropertyName("bedtimeStart")] public string? BedtimeStart { get; set; }

    /// <summary>Bedtime end as "HH:mm" local time.</summary>
    [JsonPropertyName("bedtimeEnd")] public string? BedtimeEnd { get; set; }
}

/// <summary>Wire shape of the web-filter portion of a RuleSet.</summary>
public sealed class WebFilterRuleDto
{
    /// <summary>Categories that must be blocked.</summary>
    [JsonPropertyName("blockedCategories")] public List<string>? BlockedCategories { get; set; }

    /// <summary>Domains always allowed.</summary>
    [JsonPropertyName("allowedDomains")] public List<string>? AllowedDomains { get; set; }

    /// <summary>Domains always blocked.</summary>
    [JsonPropertyName("blockedDomains")] public List<string>? BlockedDomains { get; set; }

    /// <summary>Whether SafeSearch-style rewriting is enforced.</summary>
    [JsonPropertyName("safeSearchEnforced")] public bool SafeSearchEnforced { get; set; }
}

/// <summary>Wire shape of a single app rule.</summary>
public sealed class AppRuleDto
{
    /// <summary>Process/package identifier (on desktop: the process name).</summary>
    [JsonPropertyName("packageId")] public string? PackageId { get; set; }

    /// <summary>Human-readable app name.</summary>
    [JsonPropertyName("appName")] public string? AppName { get; set; }

    /// <summary>One of allow|block|time_limit.</summary>
    [JsonPropertyName("action")] public string? Action { get; set; }

    /// <summary>Per-app daily limit for time_limit rules.</summary>
    [JsonPropertyName("dailyLimitMinutes")] public int? DailyLimitMinutes { get; set; }
}

/// <summary>Wire shape of a scheduled routine window (see packages/shared-types §2 Routine).</summary>
public sealed class RoutineDto
{
    /// <summary>Server-side routine id.</summary>
    [JsonPropertyName("id")] public string? Id { get; set; }

    /// <summary>Display name, e.g. "Homework".</summary>
    [JsonPropertyName("name")] public string? Name { get; set; }

    /// <summary>Window start as "HH:mm" local; may be later than <see cref="EndTime"/> (overnight).</summary>
    [JsonPropertyName("startTime")] public string? StartTime { get; set; }

    /// <summary>Window end as "HH:mm" local.</summary>
    [JsonPropertyName("endTime")] public string? EndTime { get; set; }

    /// <summary>Days the window starts on; 1=Monday..7=Sunday (0=Sunday also accepted). Empty = every day.</summary>
    [JsonPropertyName("days")] public List<int>? Days { get; set; }

    /// <summary>Package/process ids blocked during the window.</summary>
    [JsonPropertyName("blockedApps")] public List<string>? BlockedApps { get; set; }

    /// <summary>Allowlist during the window (parsed for wire fidelity; not enforced on desktop).</summary>
    [JsonPropertyName("allowedApps")] public List<string>? AllowedApps { get; set; }
}

/// <summary>Wire shape of GET /v1/rules/:childId (see packages/shared-types §2 RuleSet).</summary>
public sealed class RuleSetDto
{
    /// <summary>Screen-time limits and bedtime window.</summary>
    [JsonPropertyName("screenTime")] public ScreenTimeRuleDto? ScreenTime { get; set; }

    /// <summary>Web-filter configuration.</summary>
    [JsonPropertyName("webFilter")] public WebFilterRuleDto? WebFilter { get; set; }

    /// <summary>App rules.</summary>
    [JsonPropertyName("appRules")] public List<AppRuleDto>? AppRules { get; set; }

    /// <summary>Scheduled routine windows.</summary>
    [JsonPropertyName("routines")] public List<RoutineDto>? Routines { get; set; }

    /// <summary>Apps always allowed, beating every block/limit (Feature #9); desktop process names.</summary>
    [JsonPropertyName("alwaysAllowedApps")] public List<string>? AlwaysAllowedApps { get; set; }

    /// <summary>Extra screen-time minutes granted today (Feature #10); reset daily server-side.</summary>
    [JsonPropertyName("bonusMinutesToday")] public int BonusMinutesToday { get; set; }
}

/// <summary>Wire shape of one blocklist category entry inside the pack (SPEC-ADDENDUM Feature #1).</summary>
public sealed class BlocklistCategoryDto
{
    /// <summary>Category key, e.g. "gambling" (matches shared-types DEFAULT_BLOCKED_CATEGORIES).</summary>
    [JsonPropertyName("category")] public string? Category { get; set; }

    /// <summary>Domains in this category.</summary>
    [JsonPropertyName("domains")] public List<string>? Domains { get; set; }

    /// <summary>Android package names in this category (synced for completeness; not enforced on desktop).</summary>
    [JsonPropertyName("appsAndroid")] public List<string>? AppsAndroid { get; set; }

    /// <summary>Windows process names in this category.</summary>
    [JsonPropertyName("appsWindows")] public List<string>? AppsWindows { get; set; }
}

/// <summary>Wire shape of GET /v1/blocklists (BlocklistPack, see packages/shared-types world-class.ts).</summary>
public sealed class BlocklistPackDto
{
    /// <summary>Pack version; bumped whenever the pack content changes.</summary>
    [JsonPropertyName("version")] public int Version { get; set; }

    /// <summary>ISO timestamp of the last pack update.</summary>
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }

    /// <summary>Per-category domain and app lists.</summary>
    [JsonPropertyName("categories")] public List<BlocklistCategoryDto>? Categories { get; set; }
}

/// <summary>A pending device command polled from GET /v1/devices/:id/commands.</summary>
public sealed class DeviceCommandDto
{
    /// <summary>Command type: lock|unlock|ring|sos_clear|rules_updated.</summary>
    [JsonPropertyName("type")] public string? Type { get; set; }

    /// <summary>Optional command payload; contents are command-specific.</summary>
    [JsonPropertyName("payload")] public JsonElement? Payload { get; set; }
}

/// <summary>Alert posted to the alerts pipeline.</summary>
public sealed class AlertDto
{
    /// <summary>Device that raised the alert.</summary>
    [JsonPropertyName("deviceId")] public string? DeviceId { get; set; }

    /// <summary>Child the alert belongs to.</summary>
    [JsonPropertyName("childId")] public string? ChildId { get; set; }

    /// <summary>Severity: info|warning|critical.</summary>
    [JsonPropertyName("severity")] public string Severity { get; set; } = "warning";

    /// <summary>Alert category, e.g. app_blocked.</summary>
    [JsonPropertyName("category")] public string Category { get; set; } = "app_blocked";

    /// <summary>Short title.</summary>
    [JsonPropertyName("title")] public string? Title { get; set; }

    /// <summary>Longer description.</summary>
    [JsonPropertyName("body")] public string? Body { get; set; }

    /// <summary>Free-form metadata.</summary>
    [JsonPropertyName("metadata")] public Dictionary<string, object>? Metadata { get; set; }
}

/// <summary>One buffered URL log row.</summary>
public sealed class UrlLogEntryDto
{
    /// <summary>ISO timestamp of the request.</summary>
    [JsonPropertyName("ts")] public string Ts { get; set; } = "";

    /// <summary>Request host.</summary>
    [JsonPropertyName("host")] public string Host { get; set; } = "";

    /// <summary>Full request URL.</summary>
    [JsonPropertyName("url")] public string Url { get; set; } = "";

    /// <summary>Blocklist category of the host, when known.</summary>
    [JsonPropertyName("category")] public string? Category { get; set; }

    /// <summary>Whether the request was blocked.</summary>
    [JsonPropertyName("blocked")] public bool Blocked { get; set; }
}

/// <summary>One buffered per-app usage aggregate.</summary>
public sealed class AppUsageEntryDto
{
    /// <summary>Local day key (yyyy-MM-dd).</summary>
    [JsonPropertyName("day")] public string Day { get; set; } = "";

    /// <summary>Process name.</summary>
    [JsonPropertyName("process")] public string Process { get; set; } = "";

    /// <summary>Minutes used that day.</summary>
    [JsonPropertyName("minutes")] public int Minutes { get; set; }
}

/// <summary>Telemetry batch POSTed to /v1/devices/:id/telemetry.</summary>
public sealed class TelemetryBatchDto
{
    /// <summary>Buffered URL log rows.</summary>
    [JsonPropertyName("urls")] public List<UrlLogEntryDto> Urls { get; set; } = [];

    /// <summary>Buffered per-app usage rows.</summary>
    [JsonPropertyName("appUsage")] public List<AppUsageEntryDto> AppUsage { get; set; } = [];

    /// <summary>Current battery percentage (100 on desktops without a battery); doubles as a heartbeat.</summary>
    [JsonPropertyName("batteryPct")] public int? BatteryPct { get; set; }

    /// <summary>True when there is anything to upload.</summary>
    [JsonIgnore] public bool HasAny => Urls.Count > 0 || AppUsage.Count > 0;

    /// <summary>
    /// Local upload cursor: the highest url_log row id included in this batch. Passed back to
    /// LocalRuleStore.MarkTelemetryUploaded so rows logged after the batch was read are not
    /// marked uploaded without being sent.
    /// </summary>
    [JsonIgnore] public long UrlLogCursor { get; set; }
}

/// <summary>One persisted activity event for POST /v1/devices/:id/activity (Feature #4, mirrors Android).</summary>
public sealed class ActivityEventDto
{
    /// <summary>ISO timestamp of the activity; server defaults to receipt time when absent.</summary>
    [JsonPropertyName("ts")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Ts { get; set; }

    /// <summary>Event type: url|app_usage|call|sms.</summary>
    [JsonPropertyName("type")] public string Type { get; set; } = "";

    /// <summary>Type-specific payload (e.g. {domain, blocked} or {app, minutes}).</summary>
    [JsonPropertyName("payload")] public Dictionary<string, object> Payload { get; set; } = [];
}

/// <summary>Batched activity upload for POST /v1/devices/:id/activity.</summary>
public sealed class ActivityEventBatchDto
{
    /// <summary>Events to persist.</summary>
    [JsonPropertyName("events")] public List<ActivityEventDto> Events { get; set; } = [];
}

/// <summary>Normalized single app rule used internally by the agent.</summary>
public sealed class AppRuleSnapshot
{
    /// <summary>Process name to match (lowercased, extension stripped).</summary>
    public string ProcessName { get; init; } = "";

    /// <summary>Human-readable app name.</summary>
    public string AppName { get; init; } = "";

    /// <summary>Normalized action: allow|block|time_limit.</summary>
    public string Action { get; init; } = "allow";

    /// <summary>Per-app daily limit for time_limit rules.</summary>
    public int? DailyLimitMinutes { get; init; }
}

/// <summary>Normalized scheduled routine window used internally by the agent.</summary>
public sealed class RoutineSnapshot
{
    /// <summary>Display name.</summary>
    public string Name { get; init; } = "";

    /// <summary>Window start (local time).</summary>
    public TimeOnly StartTime { get; init; }

    /// <summary>Window end (local time).</summary>
    public TimeOnly EndTime { get; init; }

    /// <summary>Days the window starts on; empty means every day.</summary>
    public HashSet<DayOfWeek> Days { get; init; } = [];

    /// <summary>Normalized process names blocked during the window.</summary>
    public List<string> BlockedApps { get; init; } = [];

    /// <summary>Normalized process names allowed during the window; non-empty = allowlist mode.</summary>
    public List<string> AllowedApps { get; init; } = [];
}

/// <summary>Normalized rule set the agent enforces locally.</summary>
public sealed class RuleSetSnapshot
{
    /// <summary>Daily screen-time budget in minutes.</summary>
    public int DailyLimitMinutes { get; init; }

    /// <summary>Weekend budget; null means "same as daily".</summary>
    public int? WeekendLimitMinutes { get; init; }

    /// <summary>Parsed bedtime start; null when unparsable/absent.</summary>
    public TimeOnly? BedtimeStart { get; init; }

    /// <summary>Parsed bedtime end; null when unparsable/absent.</summary>
    public TimeOnly? BedtimeEnd { get; init; }

    /// <summary>Blocked categories.</summary>
    public List<string> BlockedCategories { get; init; } = [];

    /// <summary>Always-allowed domains.</summary>
    public List<string> AllowedDomains { get; init; } = [];

    /// <summary>Always-blocked domains.</summary>
    public List<string> BlockedDomains { get; init; } = [];

    /// <summary>Whether SafeSearch rewrite is enforced.</summary>
    public bool SafeSearchEnforced { get; init; }

    /// <summary>App rules.</summary>
    public List<AppRuleSnapshot> AppRules { get; init; } = [];

    /// <summary>Scheduled routine windows.</summary>
    public List<RoutineSnapshot> Routines { get; init; } = [];

    /// <summary>Normalized process names that always beat blocks/limits (Feature #9).</summary>
    public List<string> AlwaysAllowedApps { get; init; } = [];

    /// <summary>Extra screen-time minutes granted today (Feature #10); 0 when the field is absent.</summary>
    public int BonusMinutesToday { get; init; }

    /// <summary>Effective daily screen-time limit for the given weekday (weekend override when set).</summary>
    public int EffectiveDailyLimit(DayOfWeek day)
    {
        var isWeekend = day is DayOfWeek.Saturday or DayOfWeek.Sunday;
        return isWeekend && WeekendLimitMinutes is { } weekend && weekend > 0 ? weekend : DailyLimitMinutes;
    }

    /// <summary>Process names blocked at <paramref name="localNow"/> by any active routine window.</summary>
    public IReadOnlyCollection<string> ActiveRoutineBlockedApps(DateTime localNow)
    {
        var blocked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var routine in Routines)
        {
            if (!TimeWindows.IsRoutineActive(localNow, routine.StartTime, routine.EndTime, routine.Days)) continue;
            foreach (var app in routine.BlockedApps) blocked.Add(app);
        }
        return blocked;
    }

    /// <summary>
    /// Union of <c>allowedApps</c> across active routines. When non-empty, mirrors the Android
    /// contract (BUG-004): during the window only these processes may run — everything else is
    /// treated as blocked. An explicit allow beats a block within the same routine.
    /// </summary>
    public IReadOnlyCollection<string> ActiveRoutineAllowedApps(DateTime localNow)
    {
        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var routine in Routines)
        {
            if (!TimeWindows.IsRoutineActive(localNow, routine.StartTime, routine.EndTime, routine.Days)) continue;
            foreach (var app in routine.AllowedApps) allowed.Add(app);
        }
        return allowed;
    }
}

/// <summary>Maps API RuleSet DTOs to the normalized internal model.</summary>
public static class RuleSetMapper
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>Serializes a snapshot for SQLite storage.</summary>
    public static string ToJson(RuleSetSnapshot snapshot) => JsonSerializer.Serialize(snapshot, JsonOptions);

    /// <summary>Deserializes a snapshot from SQLite storage.</summary>
    public static RuleSetSnapshot? FromJson(string json) => JsonSerializer.Deserialize<RuleSetSnapshot>(json, JsonOptions);

    /// <summary>Maps the API DTO to the normalized internal model.</summary>
    public static RuleSetSnapshot FromDto(RuleSetDto dto)
    {
        var st = dto.ScreenTime ?? new ScreenTimeRuleDto();
        var wf = dto.WebFilter ?? new WebFilterRuleDto();
        return new RuleSetSnapshot
        {
            DailyLimitMinutes = Math.Max(0, st.DailyLimitMinutes),
            // NOTE: weekendLimitMinutes <= 0 is treated as "no override" (simplest interpretation).
            WeekendLimitMinutes = st.WeekendLimitMinutes is > 0 ? st.WeekendLimitMinutes : null,
            BedtimeStart = TryTime(st.BedtimeStart),
            BedtimeEnd = TryTime(st.BedtimeEnd),
            BlockedCategories = CleanList(wf.BlockedCategories),
            AllowedDomains = CleanList(wf.AllowedDomains),
            BlockedDomains = CleanList(wf.BlockedDomains),
            SafeSearchEnforced = wf.SafeSearchEnforced,
            AppRules = dto.AppRules?
                .Where(r => !string.IsNullOrWhiteSpace(r.PackageId))
                .Select(r => new AppRuleSnapshot
                {
                    ProcessName = NormalizeProcessName(r.PackageId!),
                    AppName = r.AppName ?? r.PackageId ?? "",
                    Action = (r.Action ?? "allow").ToLowerInvariant(),
                    DailyLimitMinutes = r.DailyLimitMinutes is > 0 ? r.DailyLimitMinutes : null,
                })
                .ToList() ?? [],
            Routines = dto.Routines?
                .Select(MapRoutine)
                .Where(r => r is not null)
                .Select(r => r!)
                .ToList() ?? [],
            // NOTE: both fields are top-level on the API RuleSet JSON and may be missing on
            // older servers; missing bonusMinutesToday maps to 0 (no extra minutes).
            AlwaysAllowedApps = (dto.AlwaysAllowedApps ?? [])
                .Where(a => !string.IsNullOrWhiteSpace(a))
                .Select(NormalizeProcessName)
                .ToList(),
            BonusMinutesToday = Math.Max(0, dto.BonusMinutesToday),
        };
    }

    private static RoutineSnapshot? MapRoutine(RoutineDto r)
    {
        var start = TryTime(r.StartTime);
        var end = TryTime(r.EndTime);
        // NOTE: routines without a usable, non-empty window cannot be enforced and are dropped.
        if (start is null || end is null || start == end) return null;
        return new RoutineSnapshot
        {
            Name = string.IsNullOrWhiteSpace(r.Name) ? "routine" : r.Name!.Trim(),
            StartTime = start.Value,
            EndTime = end.Value,
            Days = r.Days?.Select(MapDay).Where(d => d is not null).Select(d => d!.Value).ToHashSet() ?? [],
            BlockedApps = (r.BlockedApps ?? [])
                .Where(a => !string.IsNullOrWhiteSpace(a))
                .Select(NormalizeProcessName)
                .ToList(),
            AllowedApps = (r.AllowedApps ?? [])
                .Where(a => !string.IsNullOrWhiteSpace(a))
                .Select(NormalizeProcessName)
                .ToList(),
        };
    }

    // NOTE: the parent app encodes 1=Monday..7=Sunday (ISO-8601), matching the API contract
    // after BUG-002 (0 is rejected upstream); 0 is still tolerated here as Sunday defensively.
    private static DayOfWeek? MapDay(int day) => day is >= 0 and <= 7 ? (DayOfWeek)(day % 7) : null;

    private static List<string> CleanList(IEnumerable<string>? items) =>
        items?.Where(i => !string.IsNullOrWhiteSpace(i)).Select(i => i.Trim().ToLowerInvariant()).ToList() ?? [];

    private static TimeOnly? TryTime(string? value) => TimeOnly.TryParse(value, out var t) ? t : null;

    /// <summary>Lowercases the name and strips a single trailing ".exe" so AppRule packageIds
    /// match Windows process names (GetProcessesByName takes the name without extension).</summary>
    public static string NormalizeProcessName(string name)
    {
        var normalized = name.Trim().ToLowerInvariant();
        return normalized.EndsWith(".exe", StringComparison.Ordinal) ? normalized[..^4] : normalized;
    }
}
