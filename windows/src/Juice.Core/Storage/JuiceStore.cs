using Juice.Core.Attribution;
using Juice.Core.Power;
using Microsoft.Data.Sqlite;

namespace Juice.Core.Storage;

/// <summary>
/// Local SQLite store for energy history.
/// </summary>
/// <remarks>
/// <para>
/// Mirrors the role of <c>JuiceCore/Store/JuiceStore.swift</c> in the macOS tree, and for
/// the same reason: the operating system's own retention is short and the app's history
/// should outlive it. On Windows, the app additionally has no history at all without
/// this, because unlike powerlog there is no system database of per-app energy to fall
/// back on.
/// </para>
/// <para>
/// Two design choices carry most of the weight.
/// </para>
/// <para>
/// Energy is accumulated into hour-aligned buckets rather than stored per sample. That
/// keeps the database small enough to retain indefinitely, and it matches the granularity
/// the charts actually draw.
/// </para>
/// <para>
/// Every bucket records how many seconds of that hour Juice was recording. Recording
/// coverage separately from energy is what allows a gap to be rendered as a gap instead
/// of as an hour of zero draw, which the repository's charting rules require.
/// </para>
/// </remarks>
public sealed class JuiceStore : IDisposable
{
    private readonly SqliteConnection _connection;
    private bool _disposed;

    private JuiceStore(SqliteConnection connection) => _connection = connection;

    /// <summary>How long raw battery samples are kept.</summary>
    /// <remarks>
    /// Matches the macOS version. Battery samples exist to draw the charge timeline, which
    /// only ever looks back days, so keeping them forever would grow the database for no
    /// benefit. Hourly energy has no such limit and is kept indefinitely.
    /// </remarks>
    public static readonly TimeSpan BatteryRetention = TimeSpan.FromDays(90);

    /// <summary>Opens, creating and migrating the database as needed.</summary>
    /// <param name="path">
    /// Database file path, or <c>:memory:</c> for a throwaway store in tests.
    /// </param>
    public static JuiceStore Open(string path)
    {
        var builder = new SqliteConnectionStringBuilder { DataSource = path };
        var connection = new SqliteConnection(builder.ToString());
        connection.Open();

        var store = new JuiceStore(connection);
        store.Migrate();
        return store;
    }

    private void Migrate()
    {
        Execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;

            -- The default page cache is far larger than this store needs. Queries run
            -- when a window opens, a few times an hour at most, over a database measured
            -- in megabytes, so holding a large cache resident for a process that is idle
            -- almost all of the time is pure cost. Negative means kibibytes.
            PRAGMA cache_size = -512;

            -- Keep scratch on disk rather than in the heap, for the same reason.
            PRAGMA temp_store = FILE;

            CREATE TABLE IF NOT EXISTS system_energy_hours (
                hour_start      INTEGER PRIMARY KEY,
                system_wh       REAL NOT NULL DEFAULT 0,
                platform_wh     REAL NOT NULL DEFAULT 0,
                covered_seconds REAL NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS app_energy_hours (
                hour_start   INTEGER NOT NULL,
                app_id       TEXT NOT NULL,
                display_name TEXT NOT NULL,
                cpu_wh       REAL NOT NULL DEFAULT 0,
                gpu_wh       REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (hour_start, app_id)
            );

            CREATE TABLE IF NOT EXISTS battery_samples (
                timestamp   INTEGER PRIMARY KEY,
                percent     REAL NOT NULL,
                on_ac       INTEGER NOT NULL,
                watts       REAL NULL
            );

            CREATE INDEX IF NOT EXISTS idx_app_energy_hour ON app_energy_hours (hour_start);
            """);
    }

    /// <summary>
    /// Aligns an instant to the start of the hour containing it, in local time.
    /// </summary>
    /// <remarks>
    /// Alignment is done in local time rather than UTC so that buckets line up with the
    /// hours a user recognises, and so that day rollups derived from them agree with the
    /// local calendar. This matters in the half-hour offset zones, where UTC hour
    /// boundaries fall in the middle of local hours.
    /// </remarks>
    public static DateTimeOffset AlignToHour(DateTimeOffset instant)
    {
        var local = instant.ToLocalTime();
        var truncated = new DateTime(local.Year, local.Month, local.Day, local.Hour, 0, 0, DateTimeKind.Unspecified);
        return new DateTimeOffset(truncated, local.Offset);
    }

    /// <summary>
    /// Records one attributed interval.
    /// </summary>
    /// <remarks>
    /// <para>
    /// An interval longer than <see cref="SamplingPolicy.MaxContinuousGap"/> is rejected
    /// outright rather than recorded. A long gap means the machine slept or Juice was not
    /// running, and the energy accumulator delta across it is real but cannot be
    /// apportioned to any particular hour. Recording it would place hours of energy into
    /// whichever bucket happened to contain the wake-up, producing a spike that never
    /// happened.
    /// </para>
    /// <para>
    /// Intervals spanning an hour boundary are split proportionally, so an interval is
    /// never attributed wholly to the hour it ended in.
    /// </para>
    /// </remarks>
    /// <returns>False when the interval was rejected as a recording gap.</returns>
    public bool RecordInterval(AttributionResult result)
    {
        var duration = result.End - result.Start;
        if (!SamplingPolicy.IsContinuous(duration)) return false;

        using var transaction = _connection.BeginTransaction();

        foreach (var (hourStart, fraction, seconds) in SplitAcrossHours(result.Start, result.End))
        {
            Execute("""
                INSERT INTO system_energy_hours (hour_start, system_wh, platform_wh, covered_seconds)
                VALUES ($hour, $system, $platform, $covered)
                ON CONFLICT(hour_start) DO UPDATE SET
                    system_wh       = system_wh + excluded.system_wh,
                    platform_wh     = platform_wh + excluded.platform_wh,
                    covered_seconds = MIN(3600.0, covered_seconds + excluded.covered_seconds);
                """,
                transaction,
                ("$hour", hourStart.ToUnixTimeSeconds()),
                ("$system", result.SystemWattHours * fraction),
                ("$platform", result.PlatformWattHours * fraction),
                ("$covered", seconds));

            foreach (var app in result.Apps)
            {
                if (app.TotalWattHours <= 0) continue;

                Execute("""
                    INSERT INTO app_energy_hours (hour_start, app_id, display_name, cpu_wh, gpu_wh)
                    VALUES ($hour, $app, $name, $cpu, $gpu)
                    ON CONFLICT(hour_start, app_id) DO UPDATE SET
                        cpu_wh       = cpu_wh + excluded.cpu_wh,
                        gpu_wh       = gpu_wh + excluded.gpu_wh,
                        display_name = excluded.display_name;
                    """,
                    transaction,
                    ("$hour", hourStart.ToUnixTimeSeconds()),
                    ("$app", app.AppId),
                    ("$name", app.DisplayName),
                    ("$cpu", app.CpuWattHours * fraction),
                    ("$gpu", app.GpuWattHours * fraction));
            }
        }

        transaction.Commit();
        return true;
    }

    /// <summary>
    /// Splits an interval into the hour buckets it touches, returning each bucket with
    /// the fraction of the interval and the number of seconds falling inside it.
    /// </summary>
    internal static IEnumerable<(DateTimeOffset HourStart, double Fraction, double Seconds)> SplitAcrossHours(
        DateTimeOffset start, DateTimeOffset end)
    {
        var total = (end - start).TotalSeconds;
        if (total <= 0) yield break;

        var cursor = start;

        while (cursor < end)
        {
            var hourStart = AlignToHour(cursor);
            var hourEnd = hourStart.AddHours(1);
            var sliceEnd = hourEnd < end ? hourEnd : end;
            var seconds = (sliceEnd - cursor).TotalSeconds;

            if (seconds > 0) yield return (hourStart, seconds / total, seconds);

            cursor = sliceEnd;
        }
    }

    /// <summary>Records a battery observation for the charge timeline.</summary>
    public void RecordBatterySample(PowerSample sample)
    {
        if (sample.BatteryPercent is not { } percent) return;

        Execute("""
            INSERT INTO battery_samples (timestamp, percent, on_ac, watts)
            VALUES ($ts, $percent, $onAc, $watts)
            ON CONFLICT(timestamp) DO UPDATE SET
                percent = excluded.percent,
                on_ac   = excluded.on_ac,
                watts   = excluded.watts;
            """,
            null,
            ("$ts", sample.Timestamp.ToUnixTimeSeconds()),
            ("$percent", percent),
            ("$onAc", sample.OnAc ? 1 : 0),
            ("$watts", (object?)sample.SystemWatts ?? DBNull.Value));
    }

    /// <summary>
    /// Returns every hour in the range, including hours with no recorded data.
    /// </summary>
    /// <remarks>
    /// Missing hours are returned with zero coverage rather than omitted. A chart needs
    /// to know an hour existed and was not measured in order to draw a gap there, and an
    /// absent row would instead let the chart join the two neighbouring points and
    /// interpolate across the hole.
    /// </remarks>
    public IReadOnlyList<HourBucket> SystemEnergyBetween(DateTimeOffset from, DateTimeOffset to)
    {
        var stored = new Dictionary<long, HourBucket>();

        using (var command = _connection.CreateCommand())
        {
            command.CommandText = """
                SELECT hour_start, system_wh, platform_wh, covered_seconds
                FROM system_energy_hours
                WHERE hour_start >= $from AND hour_start < $to
                ORDER BY hour_start;
                """;
            command.Parameters.AddWithValue("$from", AlignToHour(from).ToUnixTimeSeconds());
            command.Parameters.AddWithValue("$to", to.ToUnixTimeSeconds());

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var unix = reader.GetInt64(0);
                stored[unix] = new HourBucket
                {
                    HourStart = DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime(),
                    SystemWattHours = reader.GetDouble(1),
                    PlatformWattHours = reader.GetDouble(2),
                    CoveredSeconds = reader.GetDouble(3),
                };
            }
        }

        var buckets = new List<HourBucket>();
        for (var hour = AlignToHour(from); hour < to; hour = hour.AddHours(1))
        {
            var unix = hour.ToUnixTimeSeconds();
            buckets.Add(stored.TryGetValue(unix, out var bucket)
                ? bucket
                : new HourBucket
                {
                    HourStart = hour,
                    SystemWattHours = 0,
                    PlatformWattHours = 0,
                    CoveredSeconds = 0,
                });
        }

        return buckets;
    }

    /// <summary>
    /// Start of the oldest hour still held, or null when nothing has been recorded.
    /// </summary>
    /// <remarks>
    /// Exists so the "all recorded" range has a real lower bound. Pruning removes hours
    /// as they age out, so this moves forward over time and is not the date Juice was
    /// installed; nothing should present it as one.
    /// </remarks>
    public DateTimeOffset? EarliestRecordedHour()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "SELECT MIN(hour_start) FROM system_energy_hours;";

        var value = command.ExecuteScalar();
        if (value is not long seconds) return null;

        return DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime();
    }

    /// <summary>Per-app energy by hour, for the app detail chart.</summary>
    public IReadOnlyList<HourlyAppEnergy> AppEnergyBetween(
        DateTimeOffset from, DateTimeOffset to, string? appId = null)
    {
        var results = new List<HourlyAppEnergy>();

        using var command = _connection.CreateCommand();
        command.CommandText = $"""
            SELECT hour_start, app_id, display_name, cpu_wh, gpu_wh
            FROM app_energy_hours
            WHERE hour_start >= $from AND hour_start < $to
              {(appId is null ? "" : "AND app_id = $app")}
            ORDER BY hour_start;
            """;
        command.Parameters.AddWithValue("$from", AlignToHour(from).ToUnixTimeSeconds());
        command.Parameters.AddWithValue("$to", to.ToUnixTimeSeconds());
        if (appId is not null) command.Parameters.AddWithValue("$app", appId);

        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            results.Add(new HourlyAppEnergy
            {
                HourStart = DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(0)).ToLocalTime(),
                AppId = reader.GetString(1),
                DisplayName = reader.GetString(2),
                CpuWattHours = reader.GetDouble(3),
                GpuWattHours = reader.GetDouble(4),
            });
        }

        return results;
    }

    /// <summary>Top apps by energy over a range, for the ranking table.</summary>
    public IReadOnlyList<DailyAppEnergy> TopApps(DateTimeOffset from, DateTimeOffset to, int limit = 25)
    {
        var results = new List<DailyAppEnergy>();

        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT app_id, display_name, SUM(cpu_wh + gpu_wh) AS total
            FROM app_energy_hours
            WHERE hour_start >= $from AND hour_start < $to
            GROUP BY app_id
            ORDER BY total DESC
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$from", AlignToHour(from).ToUnixTimeSeconds());
        command.Parameters.AddWithValue("$to", to.ToUnixTimeSeconds());
        command.Parameters.AddWithValue("$limit", limit);

        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            results.Add(new DailyAppEnergy
            {
                Day = from.ToLocalTime().ToString("yyyy-MM-dd"),
                AppId = reader.GetString(0),
                DisplayName = reader.GetString(1),
                WattHours = reader.GetDouble(2),
            });
        }

        return results;
    }

    /// <summary>Battery samples for the charge timeline.</summary>
    public IReadOnlyList<BatteryPoint> BatteryBetween(DateTimeOffset from, DateTimeOffset to)
    {
        var results = new List<BatteryPoint>();

        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT timestamp, percent, on_ac, watts
            FROM battery_samples
            WHERE timestamp >= $from AND timestamp < $to
            ORDER BY timestamp;
            """;
        command.Parameters.AddWithValue("$from", from.ToUnixTimeSeconds());
        command.Parameters.AddWithValue("$to", to.ToUnixTimeSeconds());

        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            results.Add(new BatteryPoint
            {
                Timestamp = DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(0)).ToLocalTime(),
                Percent = reader.GetDouble(1),
                OnAc = reader.GetInt64(2) != 0,
                Watts = reader.IsDBNull(3) ? null : reader.GetDouble(3),
            });
        }

        return results;
    }

    /// <summary>
    /// Drops battery samples older than <see cref="BatteryRetention"/>.
    /// </summary>
    /// <remarks>
    /// Hourly energy is deliberately never pruned. It is small, it is the thing that makes
    /// Juice's history outlast the operating system's own retention, and deleting it would
    /// throw away the only copy.
    /// </remarks>
    public int Prune(DateTimeOffset now)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "DELETE FROM battery_samples WHERE timestamp < $cutoff;";
        command.Parameters.AddWithValue("$cutoff", (now - BatteryRetention).ToUnixTimeSeconds());
        return command.ExecuteNonQuery();
    }

    private void Execute(string sql, SqliteTransaction? transaction = null, params (string Name, object Value)[] parameters)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        if (transaction is not null) command.Transaction = transaction;

        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);

        command.ExecuteNonQuery();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _connection.Dispose();
    }
}
