import Foundation
import JuiceXPCShared

/// The exported XPC object implementing ``HelperProtocol``.
final class HelperService: NSObject, HelperProtocol {
    /// Human-readable helper build version, reported via handshake.
    static let helperVersion = "1.2.0"
    /// Captured before the XPC listener starts. An old process therefore keeps
    /// reporting the bytes it actually launched from even if Sparkle replaces
    /// the app bundle at the same filesystem path later.
    private static let processStartFingerprint =
        HelperExecutableFingerprint.currentExecutable() ?? "unavailable"

    static func prepareRuntimeIdentity() {
        _ = processStartFingerprint
    }

    private let reader: PowerlogReader
    private let liveReader: LiveEnergyReader

    init(reader: PowerlogReader = PowerlogReader(), liveReader: LiveEnergyReader = LiveEnergyReader()) {
        self.reader = reader
        self.liveReader = liveReader
    }

    func handshake(reply: @escaping (Int, String) -> Void) {
        reply(
            JuiceXPC.protocolVersion,
            "\(Self.helperVersion)|\(HelperExecutableFingerprint.replyPrefix)\(Self.processStartFingerprint)")
    }

    func fetchEnergyIntervals(sinceEpoch: Double, reply: @escaping (Data?, NSError?) -> Void) {
        fetchEncoded(sinceEpoch: sinceEpoch, reply: reply) { since in
            try reader.fetchIntervals(sinceEpoch: since)
        }
    }

    func fetchBatteryLevels(sinceEpoch: Double, reply: @escaping (Data?, NSError?) -> Void) {
        fetchEncoded(sinceEpoch: sinceEpoch, reply: reply) { since in
            try reader.fetchBatteryLevels(sinceEpoch: since)
        }
    }

    func fetchLiveEnergySample(reply: @escaping (Data?, NSError?) -> Void) {
        // No sinceEpoch to validate: the snapshot is a single point in time.
        do {
            let snapshot = liveReader.snapshot()
            let data = try JSONEncoder().encode(snapshot)
            reply(data, nil)
        } catch let error as NSError where error.domain == HelperError.domain {
            reply(nil, error)
        } catch {
            reply(nil, HelperError.error(.internalError, message: error.localizedDescription))
        }
    }

    /// Shared validation, JSON encoding, and error mapping for fetch methods.
    private func fetchEncoded<T: Encodable>(
        sinceEpoch: Double,
        reply: @escaping (Data?, NSError?) -> Void,
        fetch: (Double) throws -> [T]
    ) {
        do {
            guard sinceEpoch.isFinite,
                  sinceEpoch <= Date().timeIntervalSince1970 + 86400 else {
                throw HelperError.error(.internalError, message: "invalid sinceEpoch")
            }
            let clampedSinceEpoch = max(sinceEpoch, 0)
            let values = try fetch(clampedSinceEpoch)
            let data = try JSONEncoder().encode(values)
            reply(data, nil)
        } catch let error as NSError where error.domain == HelperError.domain {
            reply(nil, error)
        } catch {
            reply(nil, HelperError.error(.internalError, message: error.localizedDescription))
        }
    }
}
