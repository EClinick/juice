import Foundation
import GRDB

/// A battery sample persisted in the local store.
public struct StoredBatterySample: Sendable, Equatable {
    public var date: Date
    public var percent: Int
    public var onAC: Bool
    public var isCharging: Bool
    public var watts: Double

    public init(date: Date, percent: Int, onAC: Bool, isCharging: Bool, watts: Double) {
        self.date = date
        self.percent = percent
        self.onAC = onAC
        self.isCharging = isCharging
        self.watts = watts
    }
}

/// One day's aggregated energy use for a single app.
public struct DailyEnergyRollup: Sendable, Equatable {
    /// Local calendar day, formatted yyyy-MM-dd.
    public var day: String
    /// Bundle identifier or launchd coalition name.
    public var appKey: String
    /// Total energy in watt-hours.
    public var wh: Double
    /// Total CPU time in hours.
    public var cpuHours: Double

    public init(day: String, appKey: String, wh: Double, cpuHours: Double) {
        self.day = day
        self.appKey = appKey
        self.wh = wh
        self.cpuHours = cpuHours
    }
}

/// The app's local SQLite store: raw battery samples, daily per-app energy
/// rollups, and a small key/value meta table.
///
/// `@unchecked Sendable`: the only stored property is a GRDB `DatabaseQueue`,
/// which serializes all database access and is safe to share across threads.
public final class JuiceStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    private static let watermarkKey = "rollup_watermark"

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// Opens (creating if needed) the store at
    /// ~/Library/Application Support/Juice/juice.sqlite.
    public static func appDefault() throws -> JuiceStore {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Juice", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return try JuiceStore(
            path: directory.appendingPathComponent("juice.sqlite").path)
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "battery_sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull().indexed()
                t.column("percent", .integer).notNull()
                t.column("on_ac", .boolean).notNull()
                t.column("is_charging", .boolean).notNull()
                t.column("watts", .double).notNull()
            }
            try db.execute(sql: """
                CREATE TABLE energy_rollup (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    day TEXT NOT NULL,
                    app_key TEXT NOT NULL,
                    wh REAL NOT NULL,
                    cpu_hours REAL NOT NULL,
                    UNIQUE(day, app_key) ON CONFLICT REPLACE
                )
                """)
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            // Sample provenance: 0 = live sampler, 1 = powerlog backfill.
            try db.alter(table: "battery_sample") { t in
                t.add(column: "source", .integer).notNull().defaults(to: 0)
            }
        }
        return migrator
    }

    // MARK: - Battery samples

    public func insertSample(
        ts: Date, percent: Int, onAC: Bool, isCharging: Bool, watts: Double
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO battery_sample (ts, percent, on_ac, is_charging, watts)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [ts.timeIntervalSince1970, percent, onAC, isCharging, watts])
        }
    }

    public func samples(since: Date) throws -> [StoredBatterySample] {
        try samples(since: since, until: Date())
    }

    public func samples(since: Date, until: Date) throws -> [StoredBatterySample] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ts, percent, on_ac, is_charging, watts
                    FROM battery_sample WHERE ts >= ? AND ts <= ? ORDER BY ts
                    """,
                arguments: [since.timeIntervalSince1970, until.timeIntervalSince1970])
            return rows.map { row in
                StoredBatterySample(
                    date: Date(timeIntervalSince1970: row["ts"]),
                    percent: row["percent"],
                    onAC: row["on_ac"],
                    isCharging: row["is_charging"],
                    watts: row["watts"])
            }
        }
    }

    /// Inserts battery samples imported from macOS's own powerlog history
    /// (`source` = 1), in one transaction.
    ///
    /// Callers are responsible for only passing points that fall inside
    /// regions not already covered by stored samples (see BackfillCoverage),
    /// which keeps backfill idempotent and free of duplicates.
    public func insertBackfillSamples(
        _ points: [(ts: Date, percent: Int, onAC: Bool, isCharging: Bool, watts: Double)]
    ) throws {
        guard !points.isEmpty else { return }
        try dbQueue.write { db in
            for point in points {
                try db.execute(
                    sql: """
                        INSERT INTO battery_sample (ts, percent, on_ac, is_charging, watts, source)
                        VALUES (?, ?, ?, ?, ?, 1)
                        """,
                    arguments: [
                        point.ts.timeIntervalSince1970, point.percent,
                        point.onAC, point.isCharging, point.watts,
                    ])
            }
        }
    }

    /// Timestamps (epoch seconds, ascending) of all samples with
    /// `since <= ts <= until`. Reads only the indexed ts column, so coverage
    /// checks over large windows stay cheap.
    public func sampleTimestamps(since: Date, until: Date) throws -> [Double] {
        try dbQueue.read { db in
            try Double.fetchAll(
                db,
                sql: "SELECT ts FROM battery_sample WHERE ts >= ? AND ts <= ? ORDER BY ts",
                arguments: [since.timeIntervalSince1970, until.timeIntervalSince1970])
        }
    }

    public func pruneSamples(olderThan cutoff: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM battery_sample WHERE ts < ?",
                arguments: [cutoff.timeIntervalSince1970])
        }
    }

    // MARK: - Energy rollups

    public func upsertRollups(_ rollups: [DailyEnergyRollup]) throws {
        guard !rollups.isEmpty else { return }
        try dbQueue.write { db in
            for rollup in rollups {
                try db.execute(
                    sql: """
                        INSERT INTO energy_rollup (day, app_key, wh, cpu_hours)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [rollup.day, rollup.appKey, rollup.wh, rollup.cpuHours])
            }
        }
    }

    /// Atomically replaces all rollup rows for the given days with `rollups`.
    ///
    /// Callers must ensure `rollups` holds complete totals for every day in
    /// `days` (i.e. the source data was fetched from each day's local start),
    /// because existing rows for those days are deleted first - including
    /// rows for app keys absent from `rollups`.
    public func replaceRollups(
        _ rollups: [DailyEnergyRollup], coveringDays days: Set<String>
    ) throws {
        guard !days.isEmpty else { return }
        try dbQueue.write { db in
            for day in days.sorted() {
                try db.execute(
                    sql: "DELETE FROM energy_rollup WHERE day = ?",
                    arguments: [day])
            }
            for rollup in rollups {
                try db.execute(
                    sql: """
                        INSERT INTO energy_rollup (day, app_key, wh, cpu_hours)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [rollup.day, rollup.appKey, rollup.wh, rollup.cpuHours])
            }
        }
    }

    /// Deletes rollup rows strictly older than the given yyyy-MM-dd day.
    public func pruneRollups(olderThanDay day: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM energy_rollup WHERE day < ?",
                arguments: [day])
        }
    }

    public func rollups(sinceDay: String) throws -> [DailyEnergyRollup] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT day, app_key, wh, cpu_hours FROM energy_rollup
                    WHERE day >= ? ORDER BY day, app_key
                    """,
                arguments: [sinceDay])
            return rows.map { row in
                DailyEnergyRollup(
                    day: row["day"],
                    appKey: row["app_key"],
                    wh: row["wh"],
                    cpuHours: row["cpu_hours"])
            }
        }
    }

    /// The earliest yyyy-MM-dd day with any rollup data, or nil when the
    /// rollup table is empty.
    public func earliestRollupDay() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT MIN(day) FROM energy_rollup")
        }
    }

    /// Number of distinct rollup days on or after the given yyyy-MM-dd day.
    public func rollupDayCount(sinceDay: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(DISTINCT day) FROM energy_rollup WHERE day >= ?",
                arguments: [sinceDay]) ?? 0
        }
    }

    // MARK: - Meta dates

    /// Reads a Date stored in the meta table (epoch seconds as text), or nil
    /// when the key is absent or unparseable.
    public func metaDate(forKey key: String) throws -> Date? {
        try dbQueue.read { db in
            let value = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key])
            return value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Upserts a Date into the meta table as epoch seconds.
    public func setMetaDate(_ date: Date, forKey key: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, String(date.timeIntervalSince1970)])
        }
    }

    // MARK: - Rollup watermark

    public func watermark() throws -> Date? {
        try metaDate(forKey: Self.watermarkKey)
    }

    public func setWatermark(_ date: Date) throws {
        try setMetaDate(date, forKey: Self.watermarkKey)
    }
}
