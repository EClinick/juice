import Foundation

/// Well-known identifiers shared between the app and the privileged helper.
public enum JuiceXPC {
    /// The launchd Mach service name the helper listens on.
    public static let machServiceName = "com.eclinick.juice.helper"

    /// The bundle identifier of the main application.
    public static let appBundleID = "com.eclinick.juice"

    /// The XPC protocol version. Bump whenever ``HelperProtocol`` changes;
    /// the app refuses to talk to a helper reporting a newer version than it
    /// knows, and gates methods added after version 1 on the handshake's
    /// reported version so older installed helpers keep serving the baseline.
    ///
    /// Version history:
    /// - 1: handshake, fetchEnergyIntervals
    /// - 2: adds fetchBatteryLevels
    public static let protocolVersion = 2
}
