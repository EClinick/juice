import Foundation
import Security
import JuiceXPCShared

/// Accepts XPC connections only from the Juice app, never from root.
///
/// Fails closed: any error while establishing the code-signing requirement
/// results in the connection being rejected.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // (a) Require the peer to be the Juice app, verified by code signature.
        guard let requirement = appRequirement else { return false }

        // Non-throwing on this SDK; XPC itself fails closed by dropping any
        // message from a peer that does not satisfy the requirement.
        connection.setCodeSigningRequirement(requirement)

        // (b) Never serve root clients; the app always runs as a normal user.
        guard connection.effectiveUserIdentifier != 0 else {
            NSLog("JuiceHelper: rejecting connection from root client")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }

    /// The release helper derives its own Team ID, then accepts only an app
    /// with the same Developer ID team and Juice's bundle identifier. This
    /// avoids baking a team-specific placeholder into source or a build script.
    private var appRequirement: String? {
        #if DEV_HELPER
        // Ad-hoc signatures have no Team ID. The development helper is only
        // installed locally and therefore can pin the bundle identifier alone.
        return #"identifier "com.eclinick.juice""#
        #else
        guard let teamID = signingTeamID() else {
            NSLog("JuiceHelper: could not determine its signing Team ID")
            return nil
        }
        return #"identifier "com.eclinick.juice" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
        #endif
    }

    private func signingTeamID() -> String? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
            let dynamicCode else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode else {
            return nil
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &signingInfo) == errSecSuccess,
            let info = signingInfo as? [String: Any] else {
            return nil
        }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
