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

    /// Replies with a JSON-encoded `LiveEnergySnapshot`: one raw cumulative
    /// energy counter per resource coalition at the instant of the call. The
    /// snapshot is stateless; the app differentiates consecutive snapshots to
    /// derive watts and rolls coalitions up to their owning .app.
    ///
    /// Added in protocol version 3; callers must gate on the handshake's
    /// reported version before invoking this against an installed helper.
    func fetchLiveEnergySample(reply: @escaping (Data?, NSError?) -> Void)

    /// Sets macOS Energy Mode by invoking `pmset <scope> powermode <mode>`,
    /// which requires root. `mode` is a ``PowerMode`` raw value (0 automatic,
    /// 1 low power, 2 high power) and `scope` is "battery", "ac", or "all";
    /// machines exposing only the legacy `lowpowermode` key reject high power.
    ///
    /// Replies with a JSON-encoded ``PowerModeState`` read back *after* the
    /// write, so callers can verify the change actually stuck rather than
    /// trusting the exit status.
    ///
    /// Added in protocol version 4 and the first mutating helper operation;
    /// callers must gate on the handshake's reported version before invoking
    /// this against an installed helper.
    func setPowerMode(_ mode: Int, scope: String, reply: @escaping (Data?, NSError?) -> Void)
}
