import Foundation
import JuiceXPCShared

/// Aggregates raw powerlog energy intervals into per-day, per-app rollups.
public enum RollupBuilder {
    /// Groups intervals by local calendar day (of the interval start) and app
    /// key, summing energy (Wh) and CPU time (hours).
    ///
    /// The app key is the bundle identifier when non-empty, else the launchd
    /// coalition name when non-empty; intervals with neither are skipped.
    /// The shared yyyy-MM-dd day-key formatter: every producer and consumer
    /// of rollup day strings must derive them from the same calendar so day
    /// boundaries agree everywhere.
    public static func dayFormatter(calendar: Calendar = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public static func dailyRollups(
        from intervals: [EnergyInterval],
        calendar: Calendar = .current
    ) -> [DailyEnergyRollup] {
        let formatter = dayFormatter(calendar: calendar)

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

    /// Keeps only the rollups of days the source demonstrably covers in full.
    ///
    /// The live powerlog retains only a few days and purges older rows, so a
    /// rebuild window can extend past what the source still has. A day is
    /// fully covered only when the earliest fetched row is at or before the
    /// day's local start (`sourceCoverageStart <= startOfDay(day)`); replacing
    /// a stored day with data from a source that starts mid-day would clobber
    /// a good full-day total with the truncated remnants.
    ///
    /// Returns the surviving rollups plus the set of fully covered day keys
    /// (suitable for `JuiceStore.replaceRollups(_:coveringDays:)`). Days whose
    /// key cannot be parsed are treated as not covered and dropped.
    public static func fullyCoveredRollups(
        _ rollups: [DailyEnergyRollup],
        sourceCoverageStart: Date,
        calendar: Calendar = .current
    ) -> (rollups: [DailyEnergyRollup], days: Set<String>) {
        let formatter = dayFormatter(calendar: calendar)
        var covered: Set<String> = []
        var uncovered: Set<String> = []
        var kept: [DailyEnergyRollup] = []
        for rollup in rollups {
            if covered.contains(rollup.day) {
                kept.append(rollup)
                continue
            }
            if uncovered.contains(rollup.day) { continue }
            // The formatter parses a day key to the day's local midnight.
            if let dayStart = formatter.date(from: rollup.day),
                sourceCoverageStart <= dayStart {
                covered.insert(rollup.day)
                kept.append(rollup)
            } else {
                uncovered.insert(rollup.day)
            }
        }
        return (kept, covered)
    }
}
