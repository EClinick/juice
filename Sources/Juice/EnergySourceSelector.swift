import Foundation
import JuiceCore

/// Which backing source actually served an energy query, so the UI can
/// caption the data honestly.
enum DataOrigin {
    /// The first query has not completed yet.
    case loading
    /// The app's own rollup store, which accumulates history indefinitely.
    case store
    /// Direct one-minute app attribution recorded on a Mac mini.
    case server
    /// The live powerlog database, which macOS only retains for about 3 days.
    case live
    /// The live source failed, so no per-app data is available.
    case unavailable
}

/// Keeps historical rows stable while an already-loaded range refreshes after
/// a surface is restored. A genuinely different range still clears immediately
/// so rows are never presented under the wrong label.
enum HistoricalReloadPolicy {
    static func shouldClear(
        loadedRange: EnergyRange?,
        requestedRange: EnergyRange
    ) -> Bool {
        loadedRange != requestedRange
    }
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
    let reportLiveFailure: @Sendable () async -> Void

    init(
        liveSource: EnergySource = PowerlogEnergySource(),
        storedApps: @escaping (JuiceStore, EnergyRange) async throws -> [AppEnergy] = {
            store, range in
            try await StoreEnergySource(store: store).topApps(range: range)
        },
        store: @escaping () -> JuiceStore? = { JuiceApp.sampler?.store },
        reportLiveFailure: @escaping @Sendable () async -> Void = {
            await MainActor.run {
                HelperRegistrationController.shared.refresh()
            }
        }
    ) {
        self.liveSource = liveSource
        self.storedApps = storedApps
        self.store = store
        self.reportLiveFailure = reportLiveFailure
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
        guard !Task.isCancelled else { return Self.cancelledResult }
        // Session is an exact start/end window resolved from battery samples,
        // not a calendar range. BatterySessionCoordinator owns that query so a
        // daily store rollup can never be mistaken for session data.
        if range == .session {
            return TopAppsResult(
                apps: [], origin: .unavailable, coverageDayCount: nil,
                errorDescription: "Battery-session energy needs an exact session window.")
        }

        if range != .today, let store = store() {
            do {
                let apps = try await storedApps(store, range)
                guard !Task.isCancelled else { return Self.cancelledResult }
                if !apps.isEmpty {
                    return TopAppsResult(
                        apps: limited(apps, to: limit),
                        origin: .store,
                        coverageDayCount: coverageDayCount(store: store, range: range),
                        errorDescription: nil
                    )
                }
            } catch is CancellationError {
                return Self.cancelledResult
            } catch {
                // Store failures retain the existing live-helper fallback, but
                // cancellation must never be reinterpreted as fallback demand.
                guard !Task.isCancelled else { return Self.cancelledResult }
            }
            // A hidden surface can cancel while the store query is running.
            // Do not turn that canceled read into a new helper/XPC fallback.
            guard !Task.isCancelled else { return Self.cancelledResult }
        }

        do {
            try Task.checkCancellation()
            let apps = try await liveSource.topApps(range: range)
            try Task.checkCancellation()
            return TopAppsResult(
                apps: limited(apps, to: limit),
                origin: .live,
                coverageDayCount: nil,
                errorDescription: nil)
        } catch is CancellationError {
            return Self.cancelledResult
        } catch {
            // XPC may report its own transport error after the surface task was
            // canceled. Do not convert that stale completion into registration
            // or recovery work for a UI that is no longer visible.
            guard !Task.isCancelled else { return Self.cancelledResult }
            await reportLiveFailure()
            return TopAppsResult(
                apps: [],
                origin: .unavailable,
                coverageDayCount: nil,
                errorDescription: error.localizedDescription)
        }
    }

    /// Callers discard canceled results before publication. Returning a neutral
    /// value keeps this convenience API nonthrowing without misreporting
    /// cancellation as helper failure or triggering registration work.
    private static var cancelledResult: TopAppsResult {
        TopAppsResult(
            apps: [],
            origin: .loading,
            coverageDayCount: nil,
            errorDescription: nil)
    }

    private func limited(_ apps: [AppEnergy], to limit: Int?) -> [AppEnergy] {
        guard let limit else { return apps }
        return Array(apps.prefix(max(0, limit)))
    }

    /// Days of history the store holds within the range, when the earliest
    /// rollup starts after the range would - i.e. the store covers less than
    /// the full selected range.
    private func coverageDayCount(store: JuiceStore, range: EnergyRange) -> Int? {
        guard range != .today, range != .session else { return nil }
        let rangeStart = StoreEnergySource.sinceDay(for: range)
        guard let earliest = try? store.earliestRollupDay(),
              earliest > rangeStart,
              let count = try? store.rollupDayCount(sinceDay: rangeStart)
        else { return nil }
        return count
    }
}
