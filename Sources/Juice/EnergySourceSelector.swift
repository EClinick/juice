import Foundation
import JuiceCore

/// Which backing source actually served an energy query, so the UI can
/// caption the data honestly.
enum DataOrigin {
    /// The first query has not completed yet.
    case loading
    /// The app's own rollup store, which accumulates history indefinitely.
    case store
    /// The live powerlog database, which macOS only retains for about 3 days.
    case live
    /// The live source failed, so no per-app data is available.
    case unavailable
}

/// Encapsulates the single policy for choosing an energy source per range:
/// Today stays on the live helper path (fresher than the 15-minute rollup
/// cadence); historical ranges (3 Days / Week / All Time) come from the app's own rollup
/// store when available, because the live powerlog database only retains
/// about three days. If stored history is unavailable, the selector tries the
/// live helper. A successful empty response is still live data; only a thrown
/// helper query is unavailable.
///
/// Both the popover and the Stats window load their app tables through this
/// selector so they always agree on what a range means.
struct EnergySourceSelector {
    let liveSource: EnergySource
    let storedApps: (JuiceStore, EnergyRange) async throws -> [AppEnergy]
    /// Resolved at query time so a store that appears after launch is used.
    let store: () -> JuiceStore?

    init(
        liveSource: EnergySource = PowerlogEnergySource(),
        storedApps: @escaping (JuiceStore, EnergyRange) async throws -> [AppEnergy] = {
            store, range in
            try await StoreEnergySource(store: store).topApps(range: range)
        },
        store: @escaping () -> JuiceStore? = { JuiceApp.sampler?.store }
    ) {
        self.liveSource = liveSource
        self.storedApps = storedApps
        self.store = store
    }

    struct TopAppsResult {
        var apps: [AppEnergy]
        var origin: DataOrigin
        /// How many days of history the store actually has, when it covers
        /// less than the selected historical range. Only set for `.store`.
        var coverageDayCount: Int?
        /// The underlying live-query error, for diagnostics and honest UI.
        var errorDescription: String?
    }

    func topApps(range: EnergyRange, limit: Int? = nil) async -> TopAppsResult {
        if range != .today, let store = store() {
            if let apps = try? await storedApps(store, range),
               !apps.isEmpty {
                return TopAppsResult(
                    apps: limited(apps, to: limit),
                    origin: .store,
                    coverageDayCount: coverageDayCount(store: store, range: range),
                    errorDescription: nil
                )
            }
        }

        do {
            let apps = try await liveSource.topApps(range: range)
            return TopAppsResult(
                apps: limited(apps, to: limit),
                origin: .live,
                coverageDayCount: nil,
                errorDescription: nil)
        } catch {
            await MainActor.run {
                HelperRegistrationController.shared.refresh()
            }
            return TopAppsResult(
                apps: [],
                origin: .unavailable,
                coverageDayCount: nil,
                errorDescription: error.localizedDescription)
        }
    }

    private func limited(_ apps: [AppEnergy], to limit: Int?) -> [AppEnergy] {
        guard let limit else { return apps }
        return Array(apps.prefix(max(0, limit)))
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
