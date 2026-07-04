import Foundation
import JuiceXPCShared
import SQLite3

/// Reads per-app energy intervals from powerlog's SQLite database.
///
/// powerlogd keeps its database open and busy, so we never open the live
/// file directly. Instead we snapshot-copy the main database file (and its
/// -wal, if present) into a private temporary directory, open the copy
/// read-only, query it, and delete the copy.
struct PowerlogReader {
    /// The live powerlog database maintained by powerlogd.
    static let systemPowerlogPath =
        "/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"

    private static let table = "PLCoalitionAgent_EventInterval_CoalitionInterval"
    private static let requiredColumns: Set<String> = [
        "timestamp", "timestampEnd", "BundleId", "LaunchdName",
        "energy", "gpu_energy_nj", "ane_energy_nj", "cpu_time"
    ]

    /// Path of the powerlog database to read. Injectable for tests.
    let databasePath: String

    init(databasePath: String = PowerlogReader.systemPowerlogPath) {
        self.databasePath = databasePath
    }

    /// Returns all intervals whose start timestamp is >= `sinceEpoch`
    /// (Unix epoch seconds), ordered by start ascending.
    func fetchIntervals(sinceEpoch: Double) throws -> [EnergyInterval] {
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: databasePath) else {
            throw HelperError.error(
                .powerlogUnavailable,
                message: "Powerlog database not found or unreadable at \(databasePath)"
            )
        }

        // 1. Snapshot copy into a fresh private temp directory.
        let tempDir = try makePrivateTempDirectory()
        defer { try? fileManager.removeItem(atPath: tempDir) }

        let snapshotPath = tempDir + "/powerlog.sqlite"
        do {
            try fileManager.copyItem(atPath: databasePath, toPath: snapshotPath)
            let walPath = databasePath + "-wal"
            if fileManager.fileExists(atPath: walPath) {
                try fileManager.copyItem(atPath: walPath, toPath: snapshotPath + "-wal")
            }
            // Deliberately skip the -shm file: it is shared-memory state for
            // the live writer and must not accompany a snapshot.
        } catch {
            throw HelperError.error(
                .powerlogUnavailable,
                message: "Failed to snapshot powerlog database: \(error.localizedDescription)"
            )
        }

        // 2. Open the snapshot read-only.
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(snapshotPath, &handle, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(openResult)"
            sqlite3_close(handle)
            throw Self.mappedError(code: openResult, context: "Failed to open snapshot: \(message)")
        }
        defer { sqlite3_close(db) }

        // 3. Schema guard: never run the query against an unexpected schema.
        try verifySchema(db: db)

        // 4. Query.
        return try queryIntervals(db: db, sinceEpoch: sinceEpoch)
    }

    // MARK: - Steps

    private func makePrivateTempDirectory() throws -> String {
        var template = Array(
            (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("juice-powerlog.XXXXXX")
                .utf8CString
        )
        guard mkdtemp(&template) != nil else {
            throw HelperError.error(
                .internalError,
                message: "mkdtemp failed: \(String(cString: strerror(errno)))"
            )
        }
        return String(cString: template)
    }

    private func verifySchema(db: OpaquePointer) throws {
        // Table present?
        let tableCount = try scalarInt(
            db: db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            textParameter: Self.table
        )
        guard tableCount == 1 else {
            throw HelperError.error(
                .schemaMismatch,
                message: "Powerlog table \(Self.table) not found; schema has changed"
            )
        }

        // All required columns present?
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "PRAGMA table_info(\(Self.table))", -1, &statement, nil
        ) == SQLITE_OK, let stmt = statement else {
            throw HelperError.error(
                .schemaMismatch,
                message: "Failed to inspect columns of \(Self.table): \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        defer { sqlite3_finalize(stmt) }

        var presentColumns = Set<String>()
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            if let namePointer = sqlite3_column_text(stmt, 1) {
                presentColumns.insert(String(cString: namePointer))
            }
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw HelperError.error(
                .internalError,
                message: "Failed to inspect columns of \(Self.table): \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        let missing = Self.requiredColumns.subtracting(presentColumns)
        guard missing.isEmpty else {
            throw HelperError.error(
                .schemaMismatch,
                message: "Powerlog table \(Self.table) is missing columns: \(missing.sorted().joined(separator: ", "))"
            )
        }
    }

    private func queryIntervals(db: OpaquePointer, sinceEpoch: Double) throws -> [EnergyInterval] {
        let sql = """
            SELECT timestamp, timestampEnd, BundleId, LaunchdName,
                   energy, gpu_energy_nj, ane_energy_nj, cpu_time
            FROM \(Self.table)
            WHERE timestamp >= ?1
            ORDER BY timestamp ASC
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            throw HelperError.error(
                .internalError,
                message: "Failed to prepare interval query: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_double(stmt, 1, sinceEpoch) == SQLITE_OK else {
            throw HelperError.error(
                .internalError,
                message: "Failed to bind interval query parameter: \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        var intervals: [EnergyInterval] = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw Self.mappedError(
                    code: stepResult,
                    context: "Interval query failed: \(String(cString: sqlite3_errmsg(db)))"
                )
            }

            intervals.append(
                EnergyInterval(
                    start: sqlite3_column_double(stmt, 0),
                    end: sqlite3_column_double(stmt, 1),
                    bundleID: columnText(stmt, 2),
                    launchdName: columnText(stmt, 3),
                    energyNJ: sqlite3_column_double(stmt, 4),
                    gpuEnergyNJ: sqlite3_column_double(stmt, 5),
                    aneEnergyNJ: sqlite3_column_double(stmt, 6),
                    cpuTime: sqlite3_column_double(stmt, 7)
                )
            )
        }
        return intervals
    }

    // MARK: - SQLite helpers

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func scalarInt(db: OpaquePointer, sql: String, textParameter: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            throw HelperError.error(
                .internalError,
                message: "Failed to prepare query: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT: have SQLite copy the string immediately.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, textParameter, -1, transient) == SQLITE_OK else {
            throw HelperError.error(
                .internalError,
                message: "Failed to bind query parameter: \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw HelperError.error(
                .internalError,
                message: "Scalar query returned no row: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func mappedError(code: Int32, context: String) -> NSError {
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return HelperError.error(.databaseBusy, message: context)
        default:
            return HelperError.error(.internalError, message: context)
        }
    }
}
