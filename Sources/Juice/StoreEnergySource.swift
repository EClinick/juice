import Foundation
import JuiceCore

/// An ``EnergySource`` backed by the local sample store. Serves the battery
/// charge timeline from persisted samples and per-app rankings from the
/// daily energy rollups, which accumulate indefinitely (unlike the live
/// powerlog database, which macOS only retains for a few days).
struct StoreEnergySource: EnergySource {
    let store: JuiceStore

    // Nonisolated async, so the synchronous store reads run on the
    // cooperative pool rather than the caller's (main) actor.
    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        let sinceDay = Self.sinceDay(for: range)
        return try store.appEnergyTotals(sinceDay: sinceDay)
            .map { total in
                AppEnergy(
                    bundleId: total.appKey,
                    displayName: PowerlogEnergySource.displayName(for: total.appKey),
                    energyWh: total.wh,
                    cpuHours: total.cpuHours
                )
            }
    }

    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample] {
        let since = until.addingTimeInterval(-Double(hours) * 3600)
        return try store.samples(since: since, until: until).map { sample in
            BatterySample(
                date: sample.date,
                percent: sample.percent,
                onAC: sample.onAC,
                isCharging: sample.isCharging)
        }
    }

    /// First rollup day (yyyy-MM-dd) included in the given range.
    static func sinceDay(for range: EnergyRange, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = RollupBuilder.dayFormatter(calendar: calendar)
        let start: Date
        switch range {
        case .session:
            // Exact session windows never use daily rollups. This fallback is
            // intentionally harmless for callers that only need a day key;
            // EnergySourceSelector rejects Session before reaching the store.
            start = now
        case .today:
            start = now
        case .threeDays:
            start = calendar.date(byAdding: .day, value: -2, to: now) ?? now
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        case .allTime:
            // Day keys are ISO-formatted, so this sorts before every stored
            // yyyy-MM-dd value and returns all history without a second query.
            return "0000-00-00"
        }
        return formatter.string(from: start)
    }
}
