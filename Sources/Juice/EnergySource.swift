import Foundation

/// Per-app energy usage over a range, aggregated by application.
struct AppEnergy: Identifiable {
    var id: String { bundleId }
    var bundleId: String
    var displayName: String
    var energyWh: Double
    var cpuHours: Double
}

/// A single point in a battery charge-level timeline.
struct BatterySample: Identifiable {
    var id: Date { date }
    var date: Date
    var percent: Int
    var onAC: Bool
    var isCharging: Bool
}

/// The time window used when ranking per-app energy usage.
enum EnergyRange: String, CaseIterable {
    case today = "Today"
    case threeDays = "3 Days"
    case week = "Week"
}

/// Supplies energy and battery data to the UI.
///
/// Implemented today by ``MockEnergySource``; a privileged helper will provide
/// the real implementation later, letting the UI stay unchanged.
protocol EnergySource {
    func topApps(range: EnergyRange) async throws -> [AppEnergy]
    /// Battery samples covering the window `[until - hours, until]`. The
    /// caller supplies `until` so the chart's x-domain and the sample query
    /// agree on the exact same window.
    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample]
}
