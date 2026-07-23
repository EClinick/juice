import Foundation

/// Per-app energy usage over a range, aggregated by application.
struct AppEnergy: Identifiable, Equatable {
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
enum EnergyRange: String, CaseIterable, Sendable {
    case session = "Session"
    case today = "Today"
    case threeDays = "3 Days"
    case week = "Week"
    case allTime = "All Time"

    /// Short label for the segmented picker; "All" keeps the segments inside
    /// the 320 px popover, the rest use the raw value.
    var pickerLabel: String {
        switch self {
        case .threeDays: return "3D"
        case .allTime: return "All"
        default: return rawValue
        }
    }

    /// Session and Today both show the shared live-power layer. The remaining
    /// ranges are historical-only and should not keep the live sampler running.
    var usesLivePower: Bool {
        self == .session || self == .today
    }

    /// The range a newly presented surface should focus based on the latest
    /// power-source reading. An unknown source keeps the conservative Today
    /// default until a real battery reading is available.
    static func initialRange(onAC: Bool?) -> EnergyRange {
        onAC == false ? .session : .today
    }
}

/// An exact, non-calendar energy query window such as one off-charger session.
struct EnergyWindow: Equatable, Sendable {
    var start: Date
    var end: Date
}

/// Whether a persisted battery timeline can be queried independently of
/// whether that timeline has accumulated any points yet.
enum TimelineAvailability {
    case loading
    case available
    case unavailable
}

/// Supplies energy and battery data to the UI.
///
/// Implemented by the privileged powerlog source and the app's local store.
protocol EnergySource {
    func topApps(range: EnergyRange) async throws -> [AppEnergy]
    /// Battery samples covering the window `[until - hours, until]`. The
    /// caller supplies `until` so the chart's x-domain and the sample query
    /// agree on the exact same window.
    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample]
}
