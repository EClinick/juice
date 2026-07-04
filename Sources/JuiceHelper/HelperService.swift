import Foundation
import JuiceXPCShared

/// The exported XPC object implementing ``HelperProtocol``.
final class HelperService: NSObject, HelperProtocol {
    /// Human-readable helper build version, reported via handshake.
    static let helperVersion = "1.0.0"

    private let reader: PowerlogReader

    init(reader: PowerlogReader = PowerlogReader()) {
        self.reader = reader
    }

    func handshake(reply: @escaping (Int, String) -> Void) {
        reply(JuiceXPC.protocolVersion, Self.helperVersion)
    }

    func fetchEnergyIntervals(sinceEpoch: Double, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            guard sinceEpoch.isFinite,
                  sinceEpoch <= Date().timeIntervalSince1970 + 86400 else {
                throw HelperError.error(.internalError, message: "invalid sinceEpoch")
            }
            let clampedSinceEpoch = max(sinceEpoch, 0)
            let intervals = try reader.fetchIntervals(sinceEpoch: clampedSinceEpoch)
            let data = try JSONEncoder().encode(intervals)
            reply(data, nil)
        } catch let error as NSError where error.domain == HelperError.domain {
            reply(nil, error)
        } catch {
            reply(nil, HelperError.error(.internalError, message: error.localizedDescription))
        }
    }
}
