import Foundation

/// Well-known identifiers shared between the app and the privileged helper.
public enum JuiceXPC {
    /// The launchd Mach service name the helper listens on.
    public static let machServiceName = "com.eclinick.juice.helper"

    /// The bundle identifier of the main application.
    public static let appBundleID = "com.eclinick.juice"

    /// The XPC protocol version. Bump whenever ``HelperProtocol`` changes
    /// incompatibly; the app refuses to talk to a helper reporting a
    /// different version.
    public static let protocolVersion = 1
}
