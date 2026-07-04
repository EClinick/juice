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
        let rollups = try store.rollups(sinceDay: sinceDay)

        struct Totals {
            var wh: Double = 0
            var cpuHours: Double = 0
        }
        var totals: [String: Totals] = [:]
        for rollup in rollups {
            totals[rollup.appKey, default: Totals()].wh += rollup.wh
            totals[rollup.appKey, default: Totals()].cpuHours += rollup.cpuHours
        }

        return totals
            .map { key, value in
                AppEnergy(
                    bundleId: key,
                    displayName: PowerlogEnergySource.displayName(for: key),
                    energyWh: value.wh,
                    cpuHours: value.cpuHours
                )
            }
            .sorted { $0.energyWh > $1.energyWh }
            .prefix(8)
            .map { $0 }
    }

    func batteryTimeline(hours: Int) async throws -> [BatterySample] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        return try store.samples(since: since).map { sample in
            BatterySample(
                date: sample.date,
                percent: sample.percent,
                onAC: sample.onAC)
        }
    }

    /// First rollup day (yyyy-MM-dd) included in the given range.
    static func sinceDay(for range: EnergyRange, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = RollupBuilder.dayFormatter(calendar: calendar)
        let start: Date
        switch range {
        case .today:
            start = now
        case .threeDays:
            start = calendar.date(byAdding: .day, value: -2, to: now) ?? now
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        }
        return formatter.string(from: start)
    }
}
