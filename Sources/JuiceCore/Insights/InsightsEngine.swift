import Foundation

/// Pure-logic engine that turns battery samples and per-app daily energy
/// into user-facing insights. Deterministic given its inputs: the only
/// clock is the `now` parameter.
public struct InsightsEngine {

    // MARK: - Tunable constants

    /// Window of "recent" samples considered for a drain anomaly.
    static let drainRecentWindow: TimeInterval = 15 * 60
    /// How far back the drain baseline reaches.
    static let drainBaselineWindow: TimeInterval = 7 * 24 * 60 * 60
    /// Minimum number of baseline samples required to trust the baseline.
    static let drainMinBaselineSamples = 60
    /// Minimum number of recent samples required to trust the recent median.
    static let drainMinRecentSamples = 5
    /// Recent median must exceed this multiple of the baseline median.
    static let drainRatioThreshold = 2.0

    /// An app needs at least this many distinct prior days of data.
    static let appAnomalyMinPriorDays = 3
    /// Today's energy must exceed this multiple of the prior daily median.
    static let appAnomalyRatioThreshold = 3.0
    /// Absolute floor (Wh) on today's energy, to avoid noise on tiny apps.
    static let appAnomalyMinTodayWh = 2.0

    /// Number of calendar days (including today) in the "week" windows.
    static let weekDayCount = 7
    /// Top app must account for at least this share of the week's energy.
    static let hogShareThreshold = 0.25
    /// Minimum total week energy (Wh) for the hog insight to be meaningful.
    static let hogMinWeekWh = 10.0

    /// Battery percent at or above which we count a sample as "full".
    static let chargingFullPercent = 98
    /// Fraction of on-AC time at full charge that triggers the habit insight.
    static let chargingFullFractionThreshold = 0.40
    /// Minimum number of on-AC samples in the window to trust the fraction.
    static let chargingMinACSamples = 200
    /// How far back the charging-habit window reaches.
    static let chargingWindow: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Entry point

    public static func insights(
        samples: [InsightSample],
        appDays: [InsightAppDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Insight] {
        var result: [Insight] = []

        if let insight = drainAnomaly(samples: samples, now: now) {
            result.append(insight)
        }
        result.append(contentsOf: appAnomalies(appDays: appDays, now: now, calendar: calendar))
        if let insight = hogOfWeek(appDays: appDays, now: now, calendar: calendar) {
            result.append(insight)
        }
        if let insight = chargingHabit(samples: samples, now: now) {
            result.append(insight)
        }

        result.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id < rhs.id
        }
        return result
    }

    /// Drops rows belonging to days with too little total energy to be a
    /// trustworthy baseline day (e.g. the first day of data collection,
    /// which may cover only a few minutes before midnight). Days whose
    /// summed wh across all apps is below `minDayTotalWh` are removed,
    /// except `todayKey`, which is always kept.
    public static func filterPartialCoverageDays(
        appDays: [InsightAppDay],
        todayKey: String,
        minDayTotalWh: Double = 5.0
    ) -> [InsightAppDay] {
        var totalByDay: [String: Double] = [:]
        for entry in appDays {
            totalByDay[entry.day, default: 0] += entry.wh
        }
        return appDays.filter { entry in
            entry.day == todayKey || totalByDay[entry.day, default: 0] >= minDayTotalWh
        }
    }

    /// Median of `values`; `nil` for an empty array.
    /// Even counts average the two middle values.
    public static func medianOf(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: - Rule 1: drain anomaly

    private static func drainAnomaly(samples: [InsightSample], now: Date) -> Insight? {
        let recentCutoff = now.addingTimeInterval(-drainRecentWindow)
        let baselineCutoff = now.addingTimeInterval(-drainBaselineWindow)

        let discharging = samples.filter { !$0.onAC && $0.watts > 0 && $0.date <= now }
        let recent = discharging.filter { $0.date > recentCutoff }
        let baseline = discharging.filter { $0.date > baselineCutoff && $0.date <= recentCutoff }

        guard baseline.count >= drainMinBaselineSamples,
              recent.count >= drainMinRecentSamples,
              let baselineMedian = medianOf(baseline.map(\.watts)),
              let recentMedian = medianOf(recent.map(\.watts)),
              baselineMedian > 0,
              recentMedian > drainRatioThreshold * baselineMedian
        else { return nil }

        let ratio = recentMedian / baselineMedian
        return Insight(
            id: "drainAnomaly:battery",
            kind: .drainAnomaly,
            title: "Draining \(format1(ratio))x faster than usual",
            detail: "Using \(format1(recentMedian)) W over the last 15 minutes vs a typical \(format1(baselineMedian)) W on battery.",
            severity: .warning
        )
    }

    // MARK: - Rule 2: per-app anomaly

    private static func appAnomalies(appDays: [InsightAppDay], now: Date, calendar: Calendar) -> [Insight] {
        let today = dayString(for: now, calendar: calendar)
        var byApp: [String: [InsightAppDay]] = [:]
        for entry in appDays {
            byApp[entry.appKey, default: []].append(entry)
        }

        var insights: [Insight] = []
        for (appKey, entries) in byApp.sorted(by: { $0.key < $1.key }) {
            var whByDay: [String: Double] = [:]
            for entry in entries {
                whByDay[entry.day, default: 0] += entry.wh
            }
            let priorDailyWh = whByDay.filter { $0.key < today }.map(\.value)
            guard priorDailyWh.count >= appAnomalyMinPriorDays,
                  let todayWh = whByDay[today],
                  let priorMedian = medianOf(priorDailyWh),
                  priorMedian > 0,
                  todayWh > appAnomalyRatioThreshold * priorMedian,
                  todayWh > appAnomalyMinTodayWh
            else { continue }

            let ratio = todayWh / priorMedian
            let name = entries.first?.displayName ?? appKey
            insights.append(Insight(
                id: "appAnomaly:\(appKey)",
                kind: .appAnomaly,
                title: "\(name) used \(format1(ratio))x its typical energy today",
                detail: "\(name) used \(format1(todayWh)) Wh today vs a typical \(format1(priorMedian)) Wh per day.",
                severity: .notice
            ))
        }
        return insights
    }

    // MARK: - Rule 3: hog of the week

    private static func hogOfWeek(appDays: [InsightAppDay], now: Date, calendar: Calendar) -> Insight? {
        guard let windowStart = calendar.date(byAdding: .day, value: -(weekDayCount - 1), to: now) else {
            return nil
        }
        let firstDay = dayString(for: windowStart, calendar: calendar)
        let today = dayString(for: now, calendar: calendar)
        let week = appDays.filter { $0.day >= firstDay && $0.day <= today }

        var whByApp: [String: Double] = [:]
        var nameByApp: [String: String] = [:]
        for entry in week {
            whByApp[entry.appKey, default: 0] += entry.wh
            if nameByApp[entry.appKey] == nil { nameByApp[entry.appKey] = entry.displayName }
        }

        let total = whByApp.values.reduce(0, +)
        guard total > hogMinWeekWh else { return nil }

        // Deterministic top pick: highest wh, appKey as tie-break.
        guard let (appKey, wh) = whByApp.min(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }) else { return nil }

        let share = wh / total
        guard share >= hogShareThreshold else { return nil }

        let percent = Int((share * 100).rounded())
        let name = nameByApp[appKey] ?? appKey
        return Insight(
            id: "hogOfWeek:\(appKey)",
            kind: .hogOfWeek,
            title: "\(name): \(percent)% of all energy this week",
            detail: "\(name) used \(format1(wh)) Wh of the \(format1(total)) Wh consumed over the last 7 days.",
            severity: .info
        )
    }

    // MARK: - Rule 4: charging habit

    private static func chargingHabit(samples: [InsightSample], now: Date) -> Insight? {
        let cutoff = now.addingTimeInterval(-chargingWindow)
        let onAC = samples.filter { $0.onAC && $0.date > cutoff && $0.date <= now }
        guard onAC.count >= chargingMinACSamples else { return nil }

        let fullCount = onAC.filter { $0.percent >= chargingFullPercent }.count
        let fraction = Double(fullCount) / Double(onAC.count)
        guard fraction >= chargingFullFractionThreshold else { return nil }

        let percent = Int((fraction * 100).rounded())
        return Insight(
            id: "chargingHabit:ac",
            kind: .chargingHabit,
            title: "Sitting at full charge \(percent)% of plugged-in time",
            detail: "Your Mac spends \(percent)% of its plugged-in time at \(chargingFullPercent)% or more. A charge limit can reduce battery wear.",
            severity: .notice
        )
    }

    // MARK: - Helpers

    private static func dayString(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func format1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
