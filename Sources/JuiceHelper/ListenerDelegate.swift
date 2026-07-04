import Foundation
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
        #if DEV_HELPER
        // Dev builds are ad-hoc signed, so we can only pin the identifier.
        let requirement = #"identifier "com.eclinick.juice""#
        #else
        let requirement = #"identifier "com.eclinick.juice" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID_PLACEHOLDER""#
        #endif

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
}
