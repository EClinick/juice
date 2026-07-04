import Foundation
import JuiceCore

/// Maps local-store data into the insights engine's inputs and returns
/// the current insights.
struct InsightsProvider {
    let store: JuiceStore

    /// Async (and never actor-isolated) so the synchronous store reads run on
    /// the cooperative pool instead of blocking the main actor.
    func currentInsights(now: Date = Date()) async -> [Insight] {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)

        let samples = ((try? store.samples(since: weekAgo)) ?? []).map {
            InsightSample(
                date: $0.date,
                percent: $0.percent,
                onAC: $0.onAC,
                isCharging: $0.isCharging,
                watts: $0.watts
            )
        }

        // Day keys must come from the same calendar as RollupBuilder so the
        // lookback boundary agrees with the stored rollup day strings.
        let calendar = Calendar.current
        let dayFormatter = RollupBuilder.dayFormatter(calendar: calendar)
        let lookbackStart = calendar.date(byAdding: .day, value: -8, to: now) ?? now
        let sinceDay = dayFormatter.string(from: lookbackStart)

        let appDays = ((try? store.rollups(sinceDay: sinceDay)) ?? []).map {
            InsightAppDay(
                day: $0.day,
                appKey: $0.appKey,
                displayName: PowerlogEnergySource.displayName(for: $0.appKey),
                wh: $0.wh
            )
        }

        // Days with barely any recorded energy (e.g. the first, partial day
        // of data collection) would poison the per-app baselines.
        let todayKey = dayFormatter.string(from: now)
        let filteredAppDays = InsightsEngine.filterPartialCoverageDays(
            appDays: appDays, todayKey: todayKey)

        return InsightsEngine.insights(samples: samples, appDays: filteredAppDays, now: now)
    }
}
