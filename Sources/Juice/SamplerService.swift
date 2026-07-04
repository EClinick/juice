import Foundation
import JuiceCore

/// Persists battery readings to the local store and keeps the daily energy
/// rollups fresh from the helper's powerlog data.
final class SamplerService {
    let store: JuiceStore
    private let helper: HelperClient

    /// Keep raw samples for 90 days.
    private static let sampleRetention: TimeInterval = 90 * 24 * 3600
    /// Rebuild rollups when the watermark is older than this.
    private static let rollupStaleness: TimeInterval = 15 * 60
    /// First-run rollup lookback when there is no watermark yet.
    private static let initialLookback: TimeInterval = 7 * 24 * 3600

    private var lastPrune: Date = .distantPast
    private(set) var lastRollupError: String?

    init(store: JuiceStore, helper: HelperClient = HelperClient()) {
        self.store = store
        self.helper = helper
    }

    /// Records one battery reading; once per hour, also prunes samples older
    /// than the retention window.
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

    /// Rebuilds the daily rollups from the helper if the watermark is missing
    /// or older than 15 minutes. Helper errors are swallowed (the helper may
    /// not be installed) but recorded in ``lastRollupError``.
    func updateRollupsIfStale() async {
        let now = Date()
        do {
            if let watermark = try store.watermark(),
               now.timeIntervalSince(watermark) < Self.rollupStaleness {
                return
            }
        } catch {
            lastRollupError = "Failed to read rollup watermark: \(error)"
            return
        }

        do {
            let since = (try? store.watermark())
                ?? now.addingTimeInterval(-Self.initialLookback)
            let intervals = try await helper.fetchIntervals(since: since)
            let rollups = RollupBuilder.dailyRollups(from: intervals)
            try store.upsertRollups(rollups)
            try store.setWatermark(now)
            lastRollupError = nil
        } catch {
            lastRollupError = "\(error)"
        }
    }
}
