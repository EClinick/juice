import Foundation
import JuiceCore

/// Persists battery readings to the local store and keeps the daily energy
/// rollups fresh from the helper's powerlog data.
///
/// An actor so that sample inserts and rollup refreshes are serialized:
/// overlapping refresh attempts (menu-bar timer plus popover opens) must not
/// double-fetch or interleave store writes. Store I/O therefore also runs on
/// the cooperative pool, never on the main actor.
actor SamplerService {
    /// The underlying store is thread-safe (GRDB serializes access), so it is
    /// safe to hand out to non-actor readers like the stats timeline.
    nonisolated let store: JuiceStore
    private let helper: HelperClient

    /// Keep raw samples for 90 days.
    private static let sampleRetention: TimeInterval = 90 * 24 * 3600
    /// Keep daily rollups for 365 days.
    private static let rollupRetentionDays = 365
    /// Refresh rollups when the last successful refresh is older than this.
    private static let rollupStaleness: TimeInterval = 15 * 60
    /// Each refresh rebuilds full days starting this many days back, so a
    /// day's stored total is always replaced by a complete recomputation and
    /// late-committed powerlog rows are re-ingested.
    private static let rebuildLookbackDays = 2
    /// First-run lookback when there is no watermark yet.
    private static let initialLookbackDays = 7

    /// Day boundaries and day keys use the same calendar as RollupBuilder.
    private let calendar = Calendar.current
    private let dayFormatter = RollupBuilder.dayFormatter()

    private var lastPrune: Date = .distantPast
    private var isRefreshing = false
    private(set) var lastRollupError: String?

    init(store: JuiceStore, helper: HelperClient = HelperClient()) {
        self.store = store
        self.helper = helper
    }

    /// Records one battery reading; once per hour, also prunes samples and
    /// rollups older than their retention windows.
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
            do {
                if let cutoff = calendar.date(
                    byAdding: .day, value: -Self.rollupRetentionDays, to: now
                ) {
                    try store.pruneRollups(olderThanDay: dayFormatter.string(from: cutoff))
                }
            } catch {
                NSLog("Juice: failed to prune energy rollups: \(error)")
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
}
