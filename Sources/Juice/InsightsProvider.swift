import Foundation
import JuiceCore

/// Maps local-store data into the insights engine's inputs and returns
/// the current insights.
struct InsightsProvider {
    let store: JuiceStore

    func currentInsights(now: Date = Date()) -> [Insight] {
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

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let sinceDay = dayFormatter.string(from: now.addingTimeInterval(-8 * 24 * 3600))

        let appDays = ((try? store.rollups(sinceDay: sinceDay)) ?? []).map {
            InsightAppDay(
                day: $0.day,
                appKey: $0.appKey,
                displayName: PowerlogEnergySource.displayName(for: $0.appKey),
                wh: $0.wh
            )
        }

        return InsightsEngine.insights(samples: samples, appDays: appDays, now: now)
    }
}
