import Foundation

/// One battery-state snapshot from powerlog's battery event table
/// (`PLBatteryAgent_EventBackward_Battery`), used to backfill the app's
/// battery-sample history for periods when Juice was not running.
public struct BatteryLevelPoint: Codable, Sendable {
    /// Snapshot time, Unix epoch seconds.
    public var ts: Double
    /// Battery level in percent, 0-100.
    public var level: Double
    /// Whether the battery was charging.
    public var isCharging: Bool
    /// Whether external power was connected.
    public var externalConnected: Bool
    /// Instantaneous power draw in watts; positive = discharging,
    /// negative = charging (same sign convention as the live sampler).
    public var watts: Double

    public init(
        ts: Double,
        level: Double,
        isCharging: Bool,
        externalConnected: Bool,
        watts: Double
    ) {
        self.ts = ts
        self.level = level
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.watts = watts
    }
}
