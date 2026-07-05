import Foundation
import JuiceCore

/// Which backing source actually served an energy query, so the UI can
/// caption the data honestly.
enum DataOrigin {
    /// The app's own rollup store, which accumulates history indefinitely.
    case store
    /// The live powerlog database, which macOS only retains for about 3 days.
    case live
    /// Hardcoded sample data - the helper is not connected.
    case sample
}

/// Encapsulates the single policy for choosing an energy source per range:
/// Today stays on the live helper path (fresher than the 15-minute rollup
/// cadence); historical ranges (3 Days / Week) come from the app's own rollup
/// store when available, because the live powerlog database only retains
/// about three days. Either path falls back to live, then to sample data.
///
/// Both the popover and the Stats window load their app tables through this
/// selector so they always agree on what a range means.
struct EnergySourceSelector {
    let liveSource: EnergySource
    let fallbackSource: EnergySource
    /// Resolved at query time so a store that appears after launch is used.
    let store: () -> JuiceStore?

    init(
        liveSource: EnergySource = PowerlogEnergySource(),
        fallbackSource: EnergySource = MockEnergySource(),
        store: @escaping () -> JuiceStore? = { JuiceApp.sampler?.store }
    ) {
        self.liveSource = liveSource
        self.fallbackSource = fallbackSource
        self.store = store
    }

    struct TopAppsResult {
        var apps: [AppEnergy]
        var origin: DataOrigin
        /// How many days of history the store actually has, when it covers
        /// less than the selected historical range. Only set for `.store`.
        var coverageDayCount: Int?
    }

    func topApps(range: EnergyRange) async -> TopAppsResult {
        if range != .today, let store = store() {
            if let apps = try? await StoreEnergySource(store: store).topApps(range: range),
               !apps.isEmpty {
                return TopAppsResult(
                    apps: apps,
                    origin: .store,
                    coverageDayCount: coverageDayCount(store: store, range: range)
                )
            }
        }

        if let apps = try? await liveSource.topApps(range: range), !apps.isEmpty {
            return TopAppsResult(apps: apps, origin: .live, coverageDayCount: nil)
        }

        let apps = (try? await fallbackSource.topApps(range: range)) ?? []
        return TopAppsResult(apps: apps, origin: .sample, coverageDayCount: nil)
    }

    /// Days of history the store holds within the range, when the earliest
    /// rollup starts after the range would - i.e. the store covers less than
    /// the full selected range.
    private func coverageDayCount(store: JuiceStore, range: EnergyRange) -> Int? {
        guard range != .today else { return nil }
        let rangeStart = StoreEnergySource.sinceDay(for: range)
        guard let earliest = try? store.earliestRollupDay(),
              earliest > rangeStart,
              let count = try? store.rollupDayCount(sinceDay: rangeStart)
        else { return nil }
        return count
    }
}
