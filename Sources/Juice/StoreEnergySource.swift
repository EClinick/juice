import Foundation
import JuiceCore

enum StoreEnergySourceError: Error {
    /// Per-app rankings stay on the live helper path; the store only serves
    /// the battery timeline.
    case notImplemented
}

/// An ``EnergySource`` backed by the local sample store. Serves the battery
/// charge timeline from persisted samples; top apps remain on the live
/// helper path.
struct StoreEnergySource: EnergySource {
    let store: JuiceStore

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        throw StoreEnergySourceError.notImplemented
    }

    // Nonisolated async, so the synchronous store read runs on the
    // cooperative pool rather than the caller's (main) actor.
    func batteryTimeline(hours: Int) async throws -> [BatterySample] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        return try store.samples(since: since).map { sample in
            BatterySample(
                date: sample.date,
                percent: sample.percent,
                onAC: sample.onAC)
        }
    }
}
