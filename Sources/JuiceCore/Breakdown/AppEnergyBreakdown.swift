import Foundation
import JuiceXPCShared

/// A per-app energy breakdown over a window: how much energy the app used,
/// which silicon component it came from, and when.
///
/// All energy values are watt-hours. Built from raw powerlog intervals by
/// ``BreakdownBuilder``; pure data, safe to construct in tests and previews.
public struct AppEnergyBreakdown: Sendable {
    /// Total energy across CPU, GPU, and Neural Engine.
    public var totalWh: Double
    /// CPU-side energy (powerlog's "energy" column).
    public var cpuWh: Double
    /// GPU energy.
    public var gpuWh: Double
    /// Apple Neural Engine energy.
    public var aneWh: Double
    /// Total CPU time in hours.
    public var cpuHours: Double
    /// Wall-clock hours summed over intervals where the app used any energy.
    public var activeHours: Double
    /// Energy per hour-aligned bucket, ascending by bucket start. Hours where
    /// the app used no energy have no bucket.
    public var hourlyWh: [(bucketStart: Date, wh: Double)]

    public init(
        totalWh: Double,
        cpuWh: Double,
        gpuWh: Double,
        aneWh: Double,
        cpuHours: Double,
        activeHours: Double,
        hourlyWh: [(bucketStart: Date, wh: Double)]
    ) {
        self.totalWh = totalWh
        self.cpuWh = cpuWh
        self.gpuWh = gpuWh
        self.aneWh = aneWh
        self.cpuHours = cpuHours
        self.activeHours = activeHours
        self.hourlyWh = hourlyWh
    }

    /// Fraction of total energy from the CPU; 0 when there is no energy.
    public var cpuShare: Double { totalWh > 0 ? cpuWh / totalWh : 0 }
    /// Fraction of total energy from the GPU; 0 when there is no energy.
    public var gpuShare: Double { totalWh > 0 ? gpuWh / totalWh : 0 }
    /// Fraction of total energy from the Neural Engine; 0 when there is no
    /// energy.
    public var aneShare: Double { totalWh > 0 ? aneWh / totalWh : 0 }
}

/// Builds ``AppEnergyBreakdown`` values from raw powerlog intervals and turns
/// them into plain-English explanations. Pure and deterministic.
public struct BreakdownBuilder {
    private static let njPerWh = 3.6e12

    /// The identity key for an interval: the bundle id when present and
    /// non-empty, otherwise the launchd coalition name. Matches the keying
    /// used when ranking top apps.
    public static func appKey(for interval: EnergyInterval) -> String? {
        let bundleID = interval.bundleID.flatMap { $0.isEmpty ? nil : $0 }
        let launchdName = interval.launchdName.flatMap { $0.isEmpty ? nil : $0 }
        return bundleID ?? launchdName
    }

    /// Aggregates the intervals belonging to `appKey` into a breakdown.
    ///
    /// Energy columns are nanojoules and are converted to watt-hours. Hourly
    /// buckets are aligned to the hour containing each interval's start in
    /// `calendar`. Intervals with zero total energy contribute nothing to
    /// active hours or buckets.
    public static func build(
        intervals: [EnergyInterval],
        appKey: String,
        calendar: Calendar = .current
    ) -> AppEnergyBreakdown {
        var cpuNJ = 0.0
        var gpuNJ = 0.0
        var aneNJ = 0.0
        var cpuSeconds = 0.0
        var activeSeconds = 0.0
        var buckets: [Date: Double] = [:]

        for interval in intervals where Self.appKey(for: interval) == appKey {
            cpuNJ += interval.energyNJ
            gpuNJ += interval.gpuEnergyNJ
            aneNJ += interval.aneEnergyNJ
            cpuSeconds += interval.cpuTime

            let totalNJ = interval.energyNJ + interval.gpuEnergyNJ + interval.aneEnergyNJ
            guard totalNJ > 0 else { continue }
            activeSeconds += max(0, interval.end - interval.start)

            let start = Date(timeIntervalSince1970: interval.start)
            if let hourStart = calendar.dateInterval(of: .hour, for: start)?.start {
                buckets[hourStart, default: 0] += totalNJ / njPerWh
            }
        }

        return AppEnergyBreakdown(
            totalWh: (cpuNJ + gpuNJ + aneNJ) / njPerWh,
            cpuWh: cpuNJ / njPerWh,
            gpuWh: gpuNJ / njPerWh,
            aneWh: aneNJ / njPerWh,
            cpuHours: cpuSeconds / 3600,
            activeHours: activeSeconds / 3600,
            hourlyWh: buckets
                .sorted { $0.key < $1.key }
                .map { (bucketStart: $0.key, wh: $0.value) }
        )
    }

    /// Plain-English sentences explaining why the app used the energy it did:
    /// which component dominated, how its activity was distributed across the
    /// window, and its average draw while active.
    ///
    /// Deterministic: derived only from `b` and `windowHours`.
    public static func explanation(for b: AppEnergyBreakdown, windowHours: Int) -> [String] {
        guard b.totalWh > 0 else {
            return ["No measurable energy use was recorded for this app in the selected range."]
        }

        var lines: [String] = []

        let cpuPercent = Int((b.cpuShare * 100).rounded())
        let gpuPercent = Int((b.gpuShare * 100).rounded())
        let anePercent = Int((b.aneShare * 100).rounded())

        if b.cpuShare >= 0.5 {
            lines.append(String(
                format: "%d%% of its energy came from CPU across %.1f CPU-hours - sustained processor work, not graphics.",
                cpuPercent, b.cpuHours))
        } else if b.gpuShare >= 0.5 {
            lines.append(
                "\(gpuPercent)% of its energy came from the GPU - typical of video playback, WebGL, or rendering.")
        } else {
            lines.append(
                "Its energy was split across components: \(cpuPercent)% CPU, \(gpuPercent)% GPU, and \(anePercent)% Neural Engine.")
        }

        if b.aneShare > 0.1, b.cpuShare >= 0.5 || b.gpuShare >= 0.5 {
            lines.append(
                "The Neural Engine contributed \(anePercent)% - on-device machine learning work.")
        }

        // A window of N hours can touch N+1 partial clock-hour buckets;
        // cap the reported count so we never claim "25 of the last 24 hours".
        let activeHourCount = min(b.hourlyWh.filter { $0.wh > 0 }.count, windowHours)
        if windowHours > 0 {
            let fraction = Double(activeHourCount) / Double(windowHours)
            var activity = "It was active in \(activeHourCount) of the last \(windowHours) hours"
            if fraction >= 0.8 {
                activity += " - roughly constant background activity."
            } else if fraction <= 0.3 {
                activity += " - concentrated bursts rather than a steady drain."
            } else {
                activity += "."
            }
            lines.append(activity)
        }

        if b.activeHours > 0 {
            lines.append(String(
                format: "It drew %.1f W on average while active.",
                b.totalWh / b.activeHours))
        }

        return lines
    }
}
