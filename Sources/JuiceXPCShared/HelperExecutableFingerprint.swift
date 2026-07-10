import CryptoKit
import Darwin
import Foundation

/// A content identity shared by the app bundle and the running daemon. Unlike
/// per-user defaults, this proves launchd is serving the exact helper payload
/// attached to the current copy of Juice.
public enum HelperExecutableFingerprint {
    public static let replyPrefix = "sha256:"

    public static func sha256(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func currentExecutable() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return sha256(at: URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL)
    }

    public static func fromHandshakeVersion(_ version: String) -> String? {
        version.split(separator: "|")
            .map(String.init)
            .first { $0.hasPrefix(replyPrefix) }
            .map { String($0.dropFirst(replyPrefix.count)) }
    }
}
