import Foundation
import JuiceXPCShared

/// An ``EnergySource`` backed by real powerlog data from the privileged
/// helper.
///
/// Not yet wired into the UI; integration happens once the helper is
/// installed (M3+). ``batteryTimeline(hours:)`` returns an empty array
/// until M4 introduces the local sample store.
struct PowerlogEnergySource: EnergySource {
    let client: HelperClient

    init(client: HelperClient = HelperClient()) {
        self.client = client
    }

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        let intervals = try await client.fetchIntervals(since: Self.rangeStart(for: range))

        struct Totals {
            var joules: Double = 0
            var cpuSeconds: Double = 0
        }
        var totals: [String: Totals] = [:]
        for interval in intervals {
            guard let key = interval.bundleID ?? interval.launchdName else { continue }
            totals[key, default: Totals()].joules +=
                interval.energyNJ + interval.gpuEnergyNJ + interval.aneEnergyNJ
            totals[key, default: Totals()].cpuSeconds += interval.cpuTime
        }

        return totals
            .map { key, value in
                AppEnergy(
                    bundleId: key,
                    displayName: Self.displayName(for: key),
                    energyWh: value.joules / 3.6e12,
                    cpuHours: value.cpuSeconds / 3600
                )
            }
            .sorted { $0.energyWh > $1.energyWh }
            .prefix(8)
            .map { $0 }
    }

    func batteryTimeline(hours: Int) async throws -> [BatterySample] {
        // Real timeline data arrives in M4 from the local sample store.
        // Return an empty timeline so the UI renders an empty chart.
        []
    }

    // MARK: - Helpers

    static func rangeStart(for range: EnergyRange, now: Date = Date()) -> Date {
        switch range {
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .threeDays:
            return now.addingTimeInterval(-3 * 24 * 3600)
        case .week:
            return now.addingTimeInterval(-7 * 24 * 3600)
        }
    }

    /// Placeholder naming: last dot-component of the identifier, capitalized.
    /// A proper bundle-id-to-name map comes later.
    static func displayName(for identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return last.capitalized
    }
}
