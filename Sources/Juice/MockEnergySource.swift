import Foundation

/// An ``EnergySource`` backed by realistic hardcoded data.
///
/// Used during development and previews until the privileged helper that
/// gathers real per-app energy data is available.
struct MockEnergySource: EnergySource {
    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        // Base figures roughly represent a single day of usage.
        let base: [AppEnergy] = [
            AppEnergy(bundleId: "com.microsoft.VSCode", displayName: "Visual Studio Code", energyWh: 56.7, cpuHours: 3.9),
            AppEnergy(bundleId: "com.microsoft.edgemac", displayName: "Microsoft Edge", energyWh: 25.1, cpuHours: 1.7),
            AppEnergy(bundleId: "com.todesktop.230313mzl4w4u92", displayName: "Cursor", energyWh: 14.7, cpuHours: 1.1),
            AppEnergy(bundleId: "com.docker.docker", displayName: "Docker Desktop", energyWh: 3.3, cpuHours: 0.4),
            AppEnergy(bundleId: "com.apple.Safari", displayName: "Safari", energyWh: 2.4, cpuHours: 0.2),
            AppEnergy(bundleId: "com.tinyspeck.slackmacgap", displayName: "Slack", energyWh: 1.8, cpuHours: 0.15),
            AppEnergy(bundleId: "com.apple.Terminal", displayName: "Terminal", energyWh: 0.9, cpuHours: 0.08)
        ]

        let scale: Double
        switch range {
        case .today: scale = 1.0
        case .threeDays: scale = 2.8
        case .week: scale = 6.4
        }

        return base.map {
            AppEnergy(
                bundleId: $0.bundleId,
                displayName: $0.displayName,
                energyWh: ($0.energyWh * scale * 10).rounded() / 10,
                cpuHours: ($0.cpuHours * scale * 10).rounded() / 10
            )
        }
    }

    func batteryTimeline(hours: Int) async throws -> [BatterySample] {
        let now = Date()
        let interval: TimeInterval = 30 * 60
        let count = max(1, hours * 2)   // one sample every 30 minutes

        var samples: [BatterySample] = []
        for step in 0..<count {
            // Oldest sample first, most recent last.
            let date = now.addingTimeInterval(-Double(count - 1 - step) * interval)
            let (percent, onAC) = Self.curveValue(atStep: step, of: count)
            samples.append(BatterySample(date: date, percent: percent, onAC: onAC))
        }
        return samples
    }

    /// A plausible discharge/charge curve across `count` samples.
    ///
    /// Discharges from full, has two charging stretches on AC, and stays
    /// within 40-100%.
    private static func curveValue(atStep step: Int, of count: Int) -> (percent: Int, onAC: Bool) {
        let progress = Double(step) / Double(max(1, count - 1))

        // Two AC (charging) windows across the timeline.
        let onAC = (progress >= 0.30 && progress < 0.42) || (progress >= 0.78 && progress < 0.92)

        let percent: Double
        switch progress {
        case ..<0.30:
            // Steady discharge from 100% to ~62%.
            percent = 100 - (progress / 0.30) * 38
        case ..<0.42:
            // Charging back up to ~90%.
            percent = 62 + ((progress - 0.30) / 0.12) * 28
        case ..<0.78:
            // Discharge from ~90% down to ~48%.
            percent = 90 - ((progress - 0.42) / 0.36) * 42
        case ..<0.92:
            // Charging up to ~85%.
            percent = 48 + ((progress - 0.78) / 0.14) * 37
        default:
            // Slight discharge to the present.
            percent = 85 - ((progress - 0.92) / 0.08) * 7
        }

        let clamped = min(100, max(40, Int(percent.rounded())))
        return (clamped, onAC)
    }
}
