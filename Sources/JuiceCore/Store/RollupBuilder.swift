import Foundation
import JuiceXPCShared

/// Aggregates raw powerlog energy intervals into per-day, per-app rollups.
public enum RollupBuilder {
    /// Groups intervals by local calendar day (of the interval start) and app
    /// key, summing energy (Wh) and CPU time (hours).
    ///
    /// The app key is the bundle identifier when non-empty, else the launchd
    /// coalition name when non-empty; intervals with neither are skipped.
    public static func dailyRollups(
        from intervals: [EnergyInterval],
        calendar: Calendar = .current
    ) -> [DailyEnergyRollup] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        struct Key: Hashable {
            var day: String
            var appKey: String
        }
        struct Totals {
            var wh: Double = 0
            var cpuHours: Double = 0
        }

        var totals: [Key: Totals] = [:]
        for interval in intervals {
            let bundleID = interval.bundleID.flatMap { $0.isEmpty ? nil : $0 }
            let launchdName = interval.launchdName.flatMap { $0.isEmpty ? nil : $0 }
            guard let appKey = bundleID ?? launchdName else { continue }

            let day = formatter.string(
                from: Date(timeIntervalSince1970: interval.start))
            let key = Key(day: day, appKey: appKey)
            totals[key, default: Totals()].wh +=
                (interval.energyNJ + interval.gpuEnergyNJ + interval.aneEnergyNJ) / 3.6e12
            totals[key, default: Totals()].cpuHours += interval.cpuTime / 3600
        }

        return totals
            .map { key, value in
                DailyEnergyRollup(
                    day: key.day, appKey: key.appKey,
                    wh: value.wh, cpuHours: value.cpuHours)
            }
            .sorted { ($0.day, $0.appKey) < ($1.day, $1.appKey) }
    }
}
