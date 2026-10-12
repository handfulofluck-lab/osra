using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace FamilyShield.Agent.Services;

/// <summary>SQLite-backed store for the synced rule set, blocklists, URL log and per-app usage counters.</summary>
public sealed class LocalRuleStore : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly string DbPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FamilyShield", "agent.db");

    private readonly string _dbPath;

    private const string SchemaSql = """
        CREATE TABLE IF NOT EXISTS ruleset (
            id INTEGER PRIMARY KEY CHECK (id=1),
            json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS blocklist_domains (
            domain TEXT PRIMARY KEY,
            category TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS blocklist_categories (
            category TEXT PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS blocklist_apps (
            name TEXT PRIMARY KEY,
            category TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS app_usage (
            day TEXT NOT NULL,
            process TEXT NOT NULL,
            minutes INTEGER NOT NULL,
            uploaded INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, process)
        );
        CREATE TABLE IF NOT EXISTS url_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            host TEXT NOT NULL,
            url TEXT NOT NULL,
            category TEXT,
            blocked INTEGER NOT NULL,
            uploaded INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS agent_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """;

    private static string Today => DateTime.Now.ToString("yyyy-MM-dd");

    private readonly ILogger<LocalRuleStore> _log;
    private readonly string _statusPath;
    private readonly object _gate = new();
    private SqliteConnection? _db;
    private RuleSetSnapshot? _current;
    private bool _paused;

    /// <summary>Latest synced rule set snapshot; null before the first successful sync.</summary>
    public RuleSetSnapshot? Current
    {
        get { lock (_gate) return _current; }
    }

    /// <summary>True while the internet is paused (Feature #11): the proxy sinkholes everything except allowedDomains.</summary>
    public bool Paused
    {
        get { lock (_gate) return _paused; }
    }

    /// <summary>
    /// Sets/clears the Feature #11 pause flag. The flag is in-memory for the proxy gate and
    /// persisted in the agent_state table (NOT the ruleset JSON blob) so a rule re-sync cannot
    /// wipe a parent's pause decision and a restart keeps it. Also refreshes status.json.
    /// </summary>
    public void SetPaused(bool paused)
    {
        EnsureOpen();
        lock (_gate)
        {
            _paused = paused;
            using var cmd = _db!.CreateCommand();
            cmd.CommandText = """
                INSERT INTO agent_state (key, value) VALUES ('paused', $v)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """;
            cmd.Parameters.AddWithValue("$v", paused ? "1" : "0");
            cmd.ExecuteNonQuery();
        }
        AgentStatus.Write(paused, HttpsInterception.IsActive, _statusPath);
    }

    /// <summary>Opens the database, creates tables and reloads the last synced rule set.</summary>
    public LocalRuleStore(ILogger<LocalRuleStore> log, string? dbPath = null, string? statusPath = null)
    {
        _log = log;
        // NOTE: dbPath/statusPath overrides exist so tests can isolate the store; production
        // uses the default %LOCALAPPDATA%\FamilyShield\agent.db and status.json locations.
        _dbPath = string.IsNullOrWhiteSpace(dbPath) ? DbPath : dbPath;
        _statusPath = string.IsNullOrWhiteSpace(statusPath) ? AgentStatus.DefaultPath : statusPath;
        try
        {
            EnsureOpen();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "LocalRuleStore initialization failed; will retry lazily on first use");
        }
    }

    /// <summary>Opens the database and creates the schema if it does not exist yet.</summary>
    public void Initialize()
    {
        lock (_gate)
        {
            if (_db is not null) return;
            Directory.CreateDirectory(Path.GetDirectoryName(_dbPath)!);
            _db = new SqliteConnection($"Data Source={_dbPath}");
            _db.Open();
            Exec(SchemaSql);
            using (var stateCmd = _db.CreateCommand())
            {
                stateCmd.CommandText = "SELECT value FROM agent_state WHERE key = 'paused'";
                _paused = stateCmd.ExecuteScalar() as string == "1";
            }
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT json FROM ruleset WHERE id = 1";
            var json = cmd.ExecuteScalar() as string;
            if (!string.IsNullOrEmpty(json))
            {
                try
                {
                    _current = RuleSetMapper.FromJson(json);
                }
                catch (Exception ex)
                {
                    _log.LogWarning(ex, "Stored rule set is corrupt; ignoring");
                }
            }
        }
    }

    /// <summary>Small built-in starter domains per category so category blocking works before any blocklist download.</summary>
    private static readonly Dictionary<string, string[]> BuiltinCategoryDomains = new(StringComparer.OrdinalIgnoreCase)
    {
        ["gambling"] = new[] { "bet365.com", "draftkings.com", "fanduel.com", "888casino.com", "pokerstars.com" },
        ["pornography"] = new[] { "pornhub.com", "xvideos.com", "xnxx.com", "redtube.com" },
    };

    /// <summary>
    /// Atomically replaces the stored rule set row and the rule-set-owned blocklist rows
    /// ('custom' blocked domains; built-in starter domains are re-seeded idempotently).
    /// Rows downloaded from the blocklist pack are left untouched — <see cref="SyncBlocklists"/>
    /// owns those.
    /// </summary>
    public void Sync(RuleSetDto dto)
    {
        var snapshot = RuleSetMapper.FromDto(dto);
        EnsureOpen();
        lock (_gate)
        {
            using var tx = _db!.BeginTransaction();
            Exec("DELETE FROM ruleset");
            // NOTE: only 'custom' rows belong to the rule set; pack-downloaded domains
            // (category <> 'custom') survive a rule re-sync so a failed pack fetch on a later
            // cycle does not wipe the previously downloaded lists.
            Exec("DELETE FROM blocklist_domains WHERE category = 'custom'");
            Exec("DELETE FROM blocklist_categories");
            using (var cmd = _db.CreateCommand())
            {
                cmd.CommandText = "INSERT INTO ruleset (id, json, updated_at) VALUES (1, $json, $ts)";
                cmd.Parameters.AddWithValue("$json", RuleSetMapper.ToJson(snapshot));
                cmd.Parameters.AddWithValue("$ts", DateTime.UtcNow.ToString("O"));
                cmd.ExecuteNonQuery();
            }
            foreach (var category in snapshot.BlockedCategories)
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "INSERT OR IGNORE INTO blocklist_categories (category) VALUES ($c)";
                cmd.Parameters.AddWithValue("$c", category);
                cmd.ExecuteNonQuery();
            }
            foreach (var domain in snapshot.BlockedDomains)
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "INSERT OR IGNORE INTO blocklist_domains (domain, category) VALUES ($d, 'custom')";
                cmd.Parameters.AddWithValue("$d", domain);
                cmd.ExecuteNonQuery();
            }
            // Seed built-in starter domains for every blocked category so category
            // blocking is demonstrable before a real blocklist download exists.
            foreach (var category in snapshot.BlockedCategories)
            {
                if (!BuiltinCategoryDomains.TryGetValue(category, out var domains)) continue;
                foreach (var domain in domains)
                {
                    using var cmd = _db.CreateCommand();
                    cmd.CommandText = "INSERT OR IGNORE INTO blocklist_domains (domain, category) VALUES ($d, $c)";
                    cmd.Parameters.AddWithValue("$d", domain);
                    cmd.Parameters.AddWithValue("$c", category);
                    cmd.ExecuteNonQuery();
                }
            }
            tx.Commit();
            _current = snapshot;
        }
    }

    /// <summary>
    /// Replaces the pack-owned blocklist rows with the downloaded pack: every
    /// blocklist_domains row whose category is not 'custom' (previous pack contents and the
    /// built-in starter domains) plus all blocklist_apps rows are dropped, then the pack's
    /// domains and Windows app names are inserted. 'custom' rows set by <see cref="Sync"/> are
    /// preserved. Built-in starter domains stay the fallback for blocked categories whenever a
    /// pack fetch fails and this method is never called (NOTE: simplest interpretation — the
    /// pack is the single source of truth once it downloads successfully).
    /// </summary>
    public void SyncBlocklists(BlocklistPackDto pack)
    {
        EnsureOpen();
        lock (_gate)
        {
            using var tx = _db!.BeginTransaction();
            Exec("DELETE FROM blocklist_domains WHERE category <> 'custom'");
            Exec("DELETE FROM blocklist_apps");
            foreach (var entry in pack.Categories ?? [])
            {
                var category = (entry.Category ?? "").Trim().ToLowerInvariant();
                if (category.Length == 0) continue;
                foreach (var domain in entry.Domains ?? [])
                {
                    var normalized = Normalize(domain);
                    if (normalized.Length == 0) continue;
                    using var cmd = _db.CreateCommand();
                    cmd.CommandText = "INSERT OR IGNORE INTO blocklist_domains (domain, category) VALUES ($d, $c)";
                    cmd.Parameters.AddWithValue("$d", normalized);
                    cmd.Parameters.AddWithValue("$c", category);
                    cmd.ExecuteNonQuery();
                }
                foreach (var app in entry.AppsWindows ?? [])
                {
                    // NOTE: names are normalized (lowercased, ".exe" stripped) so process
                    // matching is exact and case-insensitive like AppRule packageIds.
                    var name = RuleSetMapper.NormalizeProcessName(app);
                    if (name.Length == 0) continue;
                    using var cmd = _db.CreateCommand();
                    cmd.CommandText = "INSERT OR IGNORE INTO blocklist_apps (name, category) VALUES ($n, $c)";
                    cmd.Parameters.AddWithValue("$n", name);
                    cmd.Parameters.AddWithValue("$c", category);
                    cmd.ExecuteNonQuery();
                }
            }
            tx.Commit();
        }
    }

    /// <summary>Blocklist category for a running process name (exact, case-insensitive), or null when not listed.</summary>
    public string? LookupAppCategory(string processName)
    {
        var name = RuleSetMapper.NormalizeProcessName(processName);
        if (name.Length == 0) return null;
        EnsureOpen();
        lock (_gate)
        {
            using var cmd = _db!.CreateCommand();
            cmd.CommandText = "SELECT category FROM blocklist_apps WHERE name = $n LIMIT 1";
            cmd.Parameters.AddWithValue("$n", name);
            return cmd.ExecuteScalar() as string;
        }
    }

    /// <summary>True when the process name appears in the synced blocklist pack apps (exact, case-insensitive).</summary>
    public bool IsBlockedApp(string processName) => LookupAppCategory(processName) is not null;

    /// <summary>True when the host (or its URL) must be blocked under the synced rule set.</summary>
    public bool ShouldBlock(string host, string url)
    {
        var rs = Current;
        if (rs is null || string.IsNullOrWhiteSpace(host)) return false;
        if (rs.AllowedDomains.Any(d => DomainMatches(host, d))) return false;
        // NOTE: blocked domains are matched exactly and by suffix (parent-domain match covers subdomains);
        // category blocking is evaluated via LookupCategory against the synced blockedCategories list.
        if (rs.BlockedDomains.Any(d => DomainMatches(host, d))) return true;
        var category = LookupCategory(host);
        return category is not null &&
               rs.BlockedCategories.Contains(category, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Returns the blocklist category for a host (exact or suffix match), or null when unknown.</summary>
    public string? LookupCategory(string host)
    {
        if (string.IsNullOrWhiteSpace(host)) return null;
        EnsureOpen();
        lock (_gate)
        {
            using var cmd = _db!.CreateCommand();
            cmd.CommandText = """
                SELECT category FROM blocklist_domains
                WHERE $host = domain OR $host LIKE '%.' || domain
                ORDER BY LENGTH(domain) DESC LIMIT 1
                """;
            cmd.Parameters.AddWithValue("$host", Normalize(host));
            return cmd.ExecuteScalar() as string;
        }
    }

    /// <summary>Minutes recorded today for a single process.</summary>
    public int MinutesUsedToday(string process) => QueryMinutes(process);

    /// <summary>Total minutes recorded today across all processes.</summary>
    public int MinutesUsedToday() => QueryMinutes(null);

    /// <summary>Bonus minutes granted today via bonus_time commands (Feature #10).</summary>
    public int BonusMinutesToday()
    {
        EnsureOpen();
        lock (_gate) return QueryBonusMinutes();
    }

    /// <summary>
    /// Adds granted bonus minutes for today (Feature #10, bonus_time command). The day is part
    /// of the agent_state key, so the counter resets at day rollover exactly like app_usage;
    /// old days' rows are kept (same retention behaviour as app_usage).
    /// </summary>
    public void AddBonusMinutes(int minutes)
    {
        if (minutes <= 0) return;
        EnsureOpen();
        lock (_gate)
        {
            var total = QueryBonusMinutes() + minutes;
            using var cmd = _db!.CreateCommand();
            cmd.CommandText = """
                INSERT INTO agent_state (key, value) VALUES ($k, $v)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """;
            cmd.Parameters.AddWithValue("$k", $"bonusMinutes:{Today}");
            cmd.Parameters.AddWithValue("$v", total.ToString(System.Globalization.CultureInfo.InvariantCulture));
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>Appends a request to the local URL log.</summary>
    public void LogUrl(string host, string url, string? category, bool blocked)
    {
        EnsureOpen();
        lock (_gate)
        {
            using var cmd = _db!.CreateCommand();
            cmd.CommandText = """
                INSERT INTO url_log (ts, host, url, category, blocked)
                VALUES ($ts, $host, $url, $cat, $blocked)
                """;
            cmd.Parameters.AddWithValue("$ts", DateTime.UtcNow.ToString("O"));
            cmd.Parameters.AddWithValue("$host", host);
            cmd.Parameters.AddWithValue("$url", url);
            cmd.Parameters.AddWithValue("$cat", (object?)category ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$blocked", blocked ? 1 : 0);
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>Adds minutes to today's usage counter for a process.</summary>
    public void AddAppMinutes(string process, int minutes)
    {
        if (minutes <= 0) return;
        EnsureOpen();
        lock (_gate)
        {
            using var cmd = _db!.CreateCommand();
            // NOTE: uploaded is reset to 0 on every accrual. The server keeps only the latest
            // telemetry batch (Redis snapshot), so the cumulative row must be re-uploaded after
            // each upload or all minutes counted afterwards would be lost permanently.
            cmd.CommandText = """
                INSERT INTO app_usage (day, process, minutes, uploaded)
                VALUES ($day, $proc, $mins, 0)
                ON CONFLICT(day, process) DO UPDATE SET minutes = minutes + excluded.minutes, uploaded = 0
                """;
            cmd.Parameters.AddWithValue("$day", Today);
            cmd.Parameters.AddWithValue("$proc", process);
            cmd.Parameters.AddWithValue("$mins", minutes);
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>Returns all buffered (not yet uploaded) URL log and app usage rows.</summary>
    public TelemetryBatchDto GetUnuploadedTelemetry()
    {
        EnsureOpen();
        lock (_gate)
        {
            var batch = new TelemetryBatchDto();
            using (var cmd = _db!.CreateCommand())
            {
                cmd.CommandText = "SELECT id, ts, host, url, category, blocked FROM url_log WHERE uploaded = 0 ORDER BY id";
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    batch.UrlLogCursor = reader.GetInt64(0);
                    batch.Urls.Add(new UrlLogEntryDto
                    {
                        Ts = reader.GetString(1),
                        Host = reader.GetString(2),
                        Url = reader.GetString(3),
                        Category = reader.IsDBNull(4) ? null : reader.GetString(4),
                        Blocked = reader.GetInt32(5) != 0,
                    });
                }
            }
            using (var cmd = _db.CreateCommand())
            {
                cmd.CommandText = "SELECT day, process, minutes FROM app_usage WHERE uploaded = 0 ORDER BY day, process";
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    batch.AppUsage.Add(new AppUsageEntryDto
                    {
                        Day = reader.GetString(0),
                        Process = reader.GetString(1),
                        Minutes = reader.GetInt32(2),
                    });
                }
            }
            return batch;
        }
    }

    /// <summary>
    /// Marks the URL log rows included in the uploaded batch (ids up to
    /// <paramref name="maxUrlLogId"/>) plus all buffered app usage rows as uploaded. Rows logged
    /// after the batch was read keep uploaded = 0 and go out with the next cycle.
    /// </summary>
    public void MarkTelemetryUploaded(long maxUrlLogId)
    {
        EnsureOpen();
        lock (_gate)
        {
            using (var cmd = _db!.CreateCommand())
            {
                cmd.CommandText = "UPDATE url_log SET uploaded = 1 WHERE uploaded = 0 AND id <= $id";
                cmd.Parameters.AddWithValue("$id", maxUrlLogId);
                cmd.ExecuteNonQuery();
            }
            // app_usage rows re-flag themselves (uploaded = 0) when new minutes accrue, so
            // marking all of them here cannot lose data.
            Exec("UPDATE app_usage SET uploaded = 1 WHERE uploaded = 0");
        }
    }

    /// <summary>Closes the database connection.</summary>
    public void Dispose()
    {
        lock (_gate)
        {
            _db?.Dispose();
            _db = null;
        }
    }

    private void EnsureOpen()
    {
        lock (_gate)
        {
            if (_db is null) Initialize();
        }
    }

    private int QueryMinutes(string? process)
    {
        EnsureOpen();
        lock (_gate)
        {
            using var cmd = _db!.CreateCommand();
            cmd.CommandText = process is null
                ? "SELECT COALESCE(SUM(minutes), 0) FROM app_usage WHERE day = $day AND process != 'idle'"
                : "SELECT COALESCE(SUM(minutes), 0) FROM app_usage WHERE day = $day AND process = $proc";
            cmd.Parameters.AddWithValue("$day", Today);
            if (process is not null) cmd.Parameters.AddWithValue("$proc", process);
            return Convert.ToInt32(cmd.ExecuteScalar());
        }
    }

    private int QueryBonusMinutes()
    {
        using var cmd = _db!.CreateCommand();
        cmd.CommandText = "SELECT value FROM agent_state WHERE key = $k";
        cmd.Parameters.AddWithValue("$k", $"bonusMinutes:{Today}");
        var raw = cmd.ExecuteScalar() as string;
        return int.TryParse(raw, System.Globalization.NumberStyles.Integer,
            System.Globalization.CultureInfo.InvariantCulture, out var n) && n > 0 ? n : 0;
    }

    private void Exec(string sql)
    {
        using var cmd = _db!.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static string Normalize(string host) => host.Trim().TrimEnd('.').ToLowerInvariant();

    private static bool DomainMatches(string host, string domain)
    {
        var h = Normalize(host);
        var d = Normalize(domain);
        return h == d || h.EndsWith("." + d, StringComparison.Ordinal);
    }
}
