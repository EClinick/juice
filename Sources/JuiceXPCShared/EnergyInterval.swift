import Foundation

/// One row from powerlog's per-coalition energy table.
///
/// Timestamps are Unix epoch seconds; energy values are nanojoules;
/// `cpuTime` is seconds.
public struct EnergyInterval: Codable, Sendable {
    /// Interval start, Unix epoch seconds.
    public var start: Double
    /// Interval end, Unix epoch seconds.
    public var end: Double
    /// Application bundle identifier, when the coalition maps to an app.
    public var bundleID: String?
    /// launchd coalition name, present for daemons and some apps.
    public var launchdName: String?
    /// Total (CPU-side) energy in nanojoules.
    public var energyNJ: Double
    /// GPU energy in nanojoules.
    public var gpuEnergyNJ: Double
    /// Apple Neural Engine energy in nanojoules.
    public var aneEnergyNJ: Double
    /// CPU time in seconds.
    public var cpuTime: Double

    public init(
        start: Double,
        end: Double,
        bundleID: String?,
        launchdName: String?,
        energyNJ: Double,
        gpuEnergyNJ: Double,
        aneEnergyNJ: Double,
        cpuTime: Double
    ) {
        self.start = start
        self.end = end
        self.bundleID = bundleID
        self.launchdName = launchdName
        self.energyNJ = energyNJ
        self.gpuEnergyNJ = gpuEnergyNJ
        self.aneEnergyNJ = aneEnergyNJ
        self.cpuTime = cpuTime
    }
}
