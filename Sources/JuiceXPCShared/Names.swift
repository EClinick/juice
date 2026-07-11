import Foundation

/// Well-known identifiers shared between the app and the privileged helper.
public enum JuiceXPC {
    #if DEV_BUILD
    /// Development builds are a separate macOS product identity so their
    /// Service Management registration can coexist with the installed app.
    public static let appBundleID = "com.eclinick.juice.dev"
    public static let helperLabel = "com.eclinick.juice.dev.helper"
    public static let defaultsSuiteName = "com.eclinick.juice.dev"
    #else
    public static let appBundleID = "com.eclinick.juice"
    public static let helperLabel = "com.eclinick.juice.helper"
    public static let defaultsSuiteName = "com.eclinick.juice"
    #endif

    /// The launchd Mach service name the helper listens on.
    public static let machServiceName = helperLabel

    /// The bundled launch-daemon property list registered by SMAppService.
    public static let daemonPlistName = "\(helperLabel).plist"

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
