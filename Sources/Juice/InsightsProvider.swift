import Foundation
import JuiceCore

/// Maps local-store data into the insights engine's inputs and returns
/// the current insights.
struct InsightsProvider {
    let store: JuiceStore

    /// Async (and never actor-isolated) so the synchronous store reads run on
    /// the cooperative pool instead of blocking the main actor.
    func currentInsights(now: Date = Date()) async -> [Insight] {
        guard !Task.isCancelled else { return [] }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)

        let storedSamples = (try? store.samples(since: weekAgo)) ?? []
        guard !Task.isCancelled else { return [] }
        var samples: [InsightSample] = []
        samples.reserveCapacity(storedSamples.count)
        for (index, sample) in storedSamples.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            samples.append(InsightSample(
                date: sample.date,
                percent: sample.percent,
                onAC: sample.onAC,
                isCharging: sample.isCharging,
                watts: sample.watts))
        }

        // Day keys must come from the same calendar as RollupBuilder so the
        // lookback boundary agrees with the stored rollup day strings.
        let calendar = Calendar.current
        let dayFormatter = RollupBuilder.dayFormatter(calendar: calendar)
        let lookbackStart = calendar.date(byAdding: .day, value: -8, to: now) ?? now
        let sinceDay = dayFormatter.string(from: lookbackStart)

        guard !Task.isCancelled else { return [] }
        let storedRollups = (try? store.rollups(sinceDay: sinceDay)) ?? []
        guard !Task.isCancelled else { return [] }
        var appDays: [InsightAppDay] = []
        appDays.reserveCapacity(storedRollups.count)
        for (index, rollup) in storedRollups.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            appDays.append(InsightAppDay(
                day: rollup.day,
                appKey: rollup.appKey,
                displayName: PowerlogEnergySource.displayName(for: rollup.appKey),
                wh: rollup.wh))
        }

        // Days with barely any recorded energy (e.g. the first, partial day
        // of data collection) would poison the per-app baselines.
        guard !Task.isCancelled else { return [] }
        let todayKey = dayFormatter.string(from: now)
        let filteredAppDays = InsightsEngine.filterPartialCoverageDays(
            appDays: appDays, todayKey: todayKey)

        guard !Task.isCancelled else { return [] }
        return InsightsEngine.insights(samples: samples, appDays: filteredAppDays, now: now)
    }
}
