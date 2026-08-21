import Foundation
import JuiceCore
import JuiceXPCShared

/// Persists battery readings to the local store and keeps the daily energy
/// rollups fresh from the helper's powerlog data.
///
/// An actor so that sample inserts and rollup refreshes are serialized:
/// overlapping refresh attempts (menu-bar timer plus popover opens) must not
/// double-fetch or interleave store writes. Store I/O therefore also runs on
/// the cooperative pool, never on the main actor.
actor SamplerService {
    private struct ServerAppBucketKey: Hashable {
        var bucketStart: Date
        var appKey: String
    }

    private struct ServerPowerAccumulator {
        var energyWh = 0.0
        var coveredDuration = 0.0
        var peakWatts = 0.0
        var coverageStart: Date?
        var coverageEnd: Date?
    }

    /// The underlying store is thread-safe (GRDB serializes access), so it is
    /// safe to hand out to non-actor readers like the stats timeline.
    nonisolated let store: JuiceStore
    private let helper: HelperClient

    /// Keep raw samples for 90 days.
    private static let sampleRetention: TimeInterval = 90 * 24 * 3600
    /// A one-minute cadence keeps permanent server power history compact
    /// enough for the All range without downsampling away short load changes.
    private static let systemPowerSampleInterval: TimeInterval = 60
    /// A Mac mini has no battery callbacks to drive rollup maintenance. Check
    /// at most once per minute from its always-on live-power stream; the
    /// existing 15-minute watermark still controls actual PowerLog fetches.
    private static let serverRollupCheckInterval: TimeInterval = 60
    /// Refresh rollups when the last successful refresh is older than this.
    private static let rollupStaleness: TimeInterval = 15 * 60
    /// Each refresh rebuilds full days starting this many days back, so a
    /// day's stored total is always replaced by a complete recomputation and
    /// late-committed powerlog rows are re-ingested.
    private static let rebuildLookbackDays = 2
    /// First-run lookback when there is no watermark yet.
    private static let initialLookbackDays = 7

    /// Backfill runs at most this often (tracked via ``backfillLastRunKey``).
    private static let backfillMinInterval: TimeInterval = 3600
    /// Backfill looks this far back from now for uncovered history.
    private static let backfillWindow: TimeInterval = 7 * 24 * 3600
    /// Meta key recording the last successful backfill run.
    static let backfillLastRunKey = "backfill_last_run"

    /// Day boundaries and day keys use the same calendar as RollupBuilder.
    private let calendar = Calendar.current
    private let dayFormatter = RollupBuilder.dayFormatter()

    private var lastPrune: Date = .distantPast
    private var lastSystemPowerSample: Date?
    private var lastSystemPowerAggregateFlush: Date?
    private var lastServerReading: LivePowerReading?
    private var lastServerReadingDate: Date?
    private var pendingSystemPower: [Date: ServerPowerAccumulator] = [:]
    /// Two-second app-energy increments accumulated between the one-minute
    /// SQLite flushes used for permanent server history.
    private var pendingServerAppEnergy: [ServerAppBucketKey: StoredSystemAppEnergyBucket] = [:]
    private var lastServerRollupCheck: Date = .distantPast
    private var isRefreshing = false
    private(set) var lastRollupError: String?

    init(store: JuiceStore, helper: HelperClient = HelperClient()) {
        self.store = store
        self.helper = helper
    }

    /// Records one battery reading; once per hour, also prunes raw battery
    /// samples. Compact daily energy rollups are retained indefinitely so the
    /// All Time range means everything Juice has recorded.
    func recordSample(_ reading: BatteryReading) {
        let now = Date()
        do {
            try store.insertSample(
                ts: now,
                percent: reading.percent,
                onAC: reading.onAC,
                isCharging: reading.isCharging,
                watts: reading.watts)
        } catch {
            NSLog("Juice: failed to insert battery sample: \(error)")
        }

        if now.timeIntervalSince(lastPrune) >= 3600 {
            lastPrune = now
            do {
                try store.pruneSamples(olderThan: now.addingTimeInterval(-Self.sampleRetention))
            } catch {
                NSLog("Juice: failed to prune battery samples: \(error)")
            }
        }
    }

    /// Records the Mac mini's combined CPU/GPU/ANE power at most once per
    /// minute. Energy analytics integrate these points and expose any gaps.
    @discardableResult
    func recordSystemPower(_ watts: Double, at now: Date = Date()) -> Bool {
        guard watts.isFinite, watts >= 0 else { return false }
        if let lastSystemPowerSample,
           now.timeIntervalSince(lastSystemPowerSample) < Self.systemPowerSampleInterval {
            return false
        }

        do {
            try store.insertSystemPowerSample(ts: now, watts: watts)
            lastSystemPowerSample = now
            return true
        } catch {
            NSLog("Juice: failed to insert system power sample: \(error)")
            return false
        }
    }

    /// Records the Mac mini's total power and keeps the same per-app daily
    /// rollup pipeline used by the battery UI advancing while the server runs.
    /// Without this path, a battery-less Mac only refreshed app history once
    /// at launch and Week / All could remain permanently empty.
    func recordServerReading(_ reading: LivePowerReading, at now: Date = Date()) async {
        if let previousDate = lastServerReadingDate,
           let lastServerReading {
            // A wall-clock correction can move helper timestamps backward.
            // Persist the completed tail and rebase every cadence timestamp;
            // otherwise all recording would stall until the clock caught up.
            if now < previousDate {
                do {
                    try persistPendingServerHistory()
                } catch {
                    NSLog("Juice: failed to persist server history before clock rebase: \(error)")
                }
                self.lastServerReading = reading
                lastServerReadingDate = now
                lastSystemPowerAggregateFlush = now
                lastServerRollupCheck = now
                return
            }
            // Duplicate source timestamps have no duration to integrate.
            guard now > previousDate else { return }
            accumulateSystemPower(
                previousWatts: lastServerReading.totalMeteredWatts,
                currentWatts: reading.totalMeteredWatts,
                start: previousDate,
                end: now)
            accumulateServerAppEnergy(SystemAppEnergyAnalytics.increments(
                previous: lastServerReading,
                current: reading,
                start: previousDate,
                end: now))
        }
        lastServerReading = reading
        lastServerReadingDate = now

        if lastSystemPowerAggregateFlush == nil {
            lastSystemPowerAggregateFlush = now
        }
        guard let lastSystemPowerAggregateFlush,
              now.timeIntervalSince(lastSystemPowerAggregateFlush)
                >= Self.systemPowerSampleInterval else {
            return
        }

        do {
            try persistPendingServerHistory()
            self.lastSystemPowerAggregateFlush = now
        } catch {
            NSLog("Juice: failed to persist server power history: \(error)")
            return
        }

        guard now.timeIntervalSince(lastServerRollupCheck)
                >= Self.serverRollupCheckInterval
        else { return }
        lastServerRollupCheck = now
        await updateRollupsIfStale()
    }

    /// Persists the in-memory tail during normal app termination.
    func flushServerHistory() {
        do {
            try persistPendingServerHistory()
        } catch {
            NSLog("Juice: failed to flush server power history: \(error)")
        }
    }

    private func persistPendingServerHistory() throws {
        let system = pendingSystemPower.map {
            StoredSystemPowerSample(
                date: $0.key,
                watts: $0.value.energyWh * 3600 / $0.value.coveredDuration,
                coveredDuration: $0.value.coveredDuration,
                energyWh: $0.value.energyWh,
                peakWatts: $0.value.peakWatts,
                coverageStart: $0.value.coverageStart,
                coverageEnd: $0.value.coverageEnd)
        }
        let apps = Array(pendingServerAppEnergy.values)
        try store.addServerPowerHistory(system: system, apps: apps)
        pendingSystemPower.removeAll(keepingCapacity: true)
        pendingServerAppEnergy.removeAll(keepingCapacity: true)
    }

    private func accumulateSystemPower(
        previousWatts: Double,
        currentWatts: Double,
        start: Date,
        end: Date
    ) {
        let duration = end.timeIntervalSince(start)
        guard duration > 0,
              duration <= 5 * 60,
              previousWatts.isFinite,
              previousWatts >= 0,
              currentWatts.isFinite,
              currentWatts >= 0 else {
            return
        }

        var segmentStart = start
        while segmentStart < end {
            guard let minute = calendar.dateInterval(of: .minute, for: segmentStart) else {
                break
            }
            let segmentEnd = min(end, minute.end)
            let segmentDuration = segmentEnd.timeIntervalSince(segmentStart)
            let startFraction = segmentStart.timeIntervalSince(start) / duration
            let endFraction = segmentEnd.timeIntervalSince(start) / duration
            let startWatts = previousWatts
                + (currentWatts - previousWatts) * startFraction
            let endWatts = previousWatts
                + (currentWatts - previousWatts) * endFraction

            var accumulator = pendingSystemPower[minute.start]
                ?? ServerPowerAccumulator()
            accumulator.energyWh += (startWatts + endWatts) / 2
                * segmentDuration / 3600
            accumulator.coveredDuration += segmentDuration
            accumulator.peakWatts = max(
                accumulator.peakWatts,
                max(startWatts, endWatts))
            accumulator.coverageStart = min(
                accumulator.coverageStart ?? segmentStart,
                segmentStart)
            accumulator.coverageEnd = max(
                accumulator.coverageEnd ?? segmentEnd,
                segmentEnd)
            pendingSystemPower[minute.start] = accumulator
            segmentStart = segmentEnd
        }
    }

    private func accumulateServerAppEnergy(
        _ increments: [StoredSystemAppEnergyBucket]
    ) {
        for increment in increments {
            let key = ServerAppBucketKey(
                bucketStart: increment.bucketStart,
                appKey: increment.appKey)
            if var pending = pendingServerAppEnergy[key] {
                pending.displayName = increment.displayName
                pending.energyWh += increment.energyWh
                pending.activeDuration += increment.activeDuration
                pending.peakWatts = max(pending.peakWatts, increment.peakWatts)
                pendingServerAppEnergy[key] = pending
            } else {
                pendingServerAppEnergy[key] = increment
            }
        }
    }

    /// Rebuilds the daily rollups from the helper if the last successful
    /// refresh is missing or older than 15 minutes.
    ///
    /// The watermark only tracks the last successful refresh time; the fetch
    /// window always starts at the local start of day a fixed lookback ago,
    /// so every rebuilt day is recomputed in full and can safely replace the
    /// stored rows for that day - but only when the source actually covers
    /// that day from its start. The live powerlog purges rows after a few
    /// days, so days older than the earliest fetched row are left untouched
    /// rather than clobbered with truncated remnants. Helper errors are
    /// swallowed (the helper may not be installed) but recorded in
    /// ``lastRollupError``.
    func updateRollupsIfStale() async {
        guard !isRefreshing else { return }

        let now = Date()
        let watermark: Date?
        do {
            watermark = try store.watermark()
        } catch {
            lastRollupError = "Failed to read rollup watermark: \(error)"
            return
        }
        if let watermark, now.timeIntervalSince(watermark) < Self.rollupStaleness {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let lookbackDays = watermark == nil
            ? Self.initialLookbackDays : Self.rebuildLookbackDays
        guard let lookbackStart = calendar.date(byAdding: .day, value: -lookbackDays, to: now)
        else {
            lastRollupError = "Failed to compute rollup fetch window"
            return
        }
        let fetchStart = calendar.startOfDay(for: lookbackStart)
        let fetchStartDay = dayFormatter.string(from: fetchStart)

        do {
            let intervals = try await helper.fetchIntervals(since: fetchStart)
            // The live powerlog retains only a few days and purges older rows,
            // so the fetch may not reach back to the requested window start.
            // Trust only the coverage the fetch demonstrates: with no rows at
            // all, nothing is demonstrably covered and no stored day may be
            // replaced.
            if let earliestStart = intervals.map(\.start).min() {
                let sourceCoverageStart = Date(timeIntervalSince1970: earliestStart)
                // Defense in depth: a day older than the fetch window would be
                // a partial recomputation and must never replace a stored full
                // day. (RollupBuilder keys by interval start, so this cannot
                // happen for well-formed helper output.)
                let rollups = RollupBuilder.dailyRollups(from: intervals, calendar: calendar)
                    .filter { $0.day >= fetchStartDay }
                // Replace a day only when the source covers it from its local
                // start; days that begin before the earliest fetched row would
                // be rebuilt from truncated remnants and must stay untouched.
                let (coveredRollups, coveredDays) = RollupBuilder.fullyCoveredRollups(
                    rollups, sourceCoverageStart: sourceCoverageStart, calendar: calendar)
                try store.replaceRollups(coveredRollups, coveringDays: coveredDays)
            }
            try store.setWatermark(now)
            lastRollupError = nil
        } catch {
            lastRollupError = "\(error)"
        }
    }

    /// Imports battery-level history that macOS itself recorded (powerlog's
    /// battery event table) for any part of the last 7 days the live sampler
    /// did not cover: time before Juice first ran, and gaps while Juice was
    /// not running.
    ///
    /// Idempotent: only points falling inside uncovered regions (computed by
    /// ``BackfillCoverage`` from the stored sample timestamps) are inserted,
    /// so re-running never duplicates the live sampler or a previous backfill.
    /// Runs at most once per hour across launches. Skips silently when the
    /// helper is unavailable or too old to serve the battery-level query;
    /// the skip is not recorded, so the next launch retries (e.g. after the
    /// user upgrades the helper).
    func backfillIfNeeded() async {
        let now = Date()
        do {
            if let lastRun = try store.metaDate(forKey: Self.backfillLastRunKey),
               now.timeIntervalSince(lastRun) < Self.backfillMinInterval {
                return
            }
        } catch {
            NSLog("Juice: failed to read backfill watermark: \(error)")
            return
        }

        let windowStart = now.addingTimeInterval(-Self.backfillWindow)
        let points: [BatteryLevelPoint]
        do {
            points = try await helper.fetchBatteryLevels(since: windowStart)
        } catch {
            // Helper not installed, unreachable, or predating the
            // battery-level query: backfill is best-effort, skip silently.
            NSLog("Juice: battery backfill skipped: \(error)")
            return
        }

        do {
            let existing = try store.sampleTimestamps(since: windowStart, until: now)
            let regions = BackfillCoverage.uncoveredRegions(
                existing: existing,
                windowStart: windowStart.timeIntervalSince1970,
                windowEnd: now.timeIntervalSince1970)
            let inserts = points
                .filter { BackfillCoverage.contains(regions, $0.ts) }
                .map { point in
                    (ts: Date(timeIntervalSince1970: point.ts),
                     percent: Int(point.level.rounded()),
                     onAC: point.externalConnected,
                     isCharging: point.isCharging,
                     watts: point.watts)
                }
            try store.insertBackfillSamples(inserts)
            try store.setMetaDate(now, forKey: Self.backfillLastRunKey)
            NSLog("Juice: backfilled \(inserts.count) battery samples from powerlog")
        } catch {
            NSLog("Juice: battery backfill failed: \(error)")
        }
    }
}
