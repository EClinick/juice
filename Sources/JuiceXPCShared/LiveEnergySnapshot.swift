import Foundation

/// One resource coalition's cumulative energy counters at a single instant.
///
/// Energy is accounted per resource coalition, not per PID: a coalition groups
/// an app's processes (and, for browsers, each renderer forms its own
/// coalition). Values are raw and stateless - the helper never differentiates.
/// The app computes watts from the difference between two snapshots and rolls
/// coalitions up to their owning .app via `leaderPath`. Raw cumulative counters
/// on the wire mean a dropped snapshot never corrupts a rate: the next delta is
/// simply taken over a longer interval.
///
/// `cpuEnergyNJ`, `gpuEnergyNJ`, and `aneEnergyNJ` are three independent SoC
/// energy domains in nanojoules; the app sums them for a per-app total.
public struct LiveEnergySample: Codable, Equatable, Sendable {
    /// Resource coalition id. Stable for the life of the coalition; the app
    /// keys baselines on it and re-baselines (no delta) when a new id appears.
    public let coalitionID: UInt64
    /// The coalition leader's pid (or the lowest visible pid when no leader is
    /// visible). Diagnostic only; attribution uses `leaderPath`.
    public let leaderPID: Int32
    /// Executable path of the leader, used to resolve the owning .app. Empty
    /// when no member path resolves; such coalitions fall into the system bucket.
    public let leaderPath: String
    /// Cumulative CPU energy (nanojoules) since the coalition formed.
    public let cpuEnergyNJ: UInt64
    /// Cumulative GPU energy (nanojoules).
    public let gpuEnergyNJ: UInt64
    /// Cumulative Apple Neural Engine energy (nanojoules).
    public let aneEnergyNJ: UInt64

    public init(
        coalitionID: UInt64,
        leaderPID: Int32,
        leaderPath: String,
        cpuEnergyNJ: UInt64,
        gpuEnergyNJ: UInt64,
        aneEnergyNJ: UInt64
    ) {
        self.coalitionID = coalitionID
        self.leaderPID = leaderPID
        self.leaderPath = leaderPath
        self.cpuEnergyNJ = cpuEnergyNJ
        self.gpuEnergyNJ = gpuEnergyNJ
        self.aneEnergyNJ = aneEnergyNJ
    }
}

/// A stateless raw snapshot of every readable coalition's energy counters.
public struct LiveEnergySnapshot: Codable, Equatable, Sendable {
    /// When the helper took the snapshot (Unix epoch seconds).
    public let timestampEpoch: Double
    public let samples: [LiveEnergySample]

    public init(timestampEpoch: Double, samples: [LiveEnergySample]) {
        self.timestampEpoch = timestampEpoch
        self.samples = samples
    }
}
