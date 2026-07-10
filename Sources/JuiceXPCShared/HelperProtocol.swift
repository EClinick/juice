import Foundation

/// The XPC interface exposed by the privileged helper.
///
/// `fetchEnergyIntervals` replies with JSON-encoded `[EnergyInterval]`
/// (or a typed NSError from the `HelperError` domain).
@objc public protocol HelperProtocol {
    /// Replies with (protocol version, helper version string). Current helpers
    /// append a SHA-256 executable fingerprint so the app can verify launchd is
    /// serving the payload bundled with this exact app build.
    func handshake(reply: @escaping (Int, String) -> Void)

    /// Replies with JSON-encoded `[EnergyInterval]` for rows whose start
    /// timestamp is at or after `sinceEpoch` (Unix epoch seconds).
    func fetchEnergyIntervals(sinceEpoch: Double, reply: @escaping (Data?, NSError?) -> Void)

    /// Replies with JSON-encoded `[BatteryLevelPoint]` for rows whose
    /// timestamp is at or after `sinceEpoch` (Unix epoch seconds).
    ///
    /// Added in protocol version 2; callers must gate on the handshake's
    /// reported version before invoking this against an installed helper.
    func fetchBatteryLevels(sinceEpoch: Double, reply: @escaping (Data?, NSError?) -> Void)
}
