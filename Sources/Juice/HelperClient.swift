import Foundation
import JuiceXPCShared

/// The app's view of the privileged helper.
enum HelperState {
    /// The helper is not installed or cannot be reached.
    case unavailable
    /// The helper responded but speaks a different protocol version.
    case versionMismatch
    /// The helper is reachable and compatible.
    case ready
}

/// Wraps the NSXPCConnection to the privileged helper with async APIs.
final class HelperClient {
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    /// Last known helper state, updated by ``checkState()``.
    private(set) var state: HelperState = .unavailable

    // MARK: - Connection management

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }

        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: JuiceXPC.machServiceName,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.invalidationHandler = { [weak self] in
            // The helper is gone (uninstalled or denied); drop the connection
            // so the next call builds a fresh one instead of failing forever.
            self?.dropConnection()
        }
        newConnection.interruptionHandler = {
            // The helper crashed or was killed; launchd relaunches it on the
            // next message, so keeping the connection is fine.
            NSLog("Juice: helper connection interrupted")
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func dropConnection() {
        lock.lock()
        defer { lock.unlock() }
        connection = nil
    }

    private func remoteProxy(
        errorHandler: @escaping (Error) -> Void
    ) -> HelperProtocol? {
        currentConnection()
            .remoteObjectProxyWithErrorHandler(errorHandler) as? HelperProtocol
    }

    // MARK: - Async API

    /// Performs the version handshake with the helper.
    /// Returns (protocol version, helper version string).
    func handshake() async throws -> (Int, String) {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShot()
            guard let proxy = remoteProxy(errorHandler: { error in
                resumed.run { continuation.resume(throwing: error) }
            }) else {
                resumed.run {
                    continuation.resume(throwing: HelperError.error(
                        .internalError, message: "Failed to create helper proxy"))
                }
                return
            }
            proxy.handshake { version, helperVersion in
                resumed.run { continuation.resume(returning: (version, helperVersion)) }
            }
        }
    }

    /// Handshakes and updates ``state`` accordingly.
    @discardableResult
    func checkState() async -> HelperState {
        do {
            let (version, _) = try await handshake()
            state = (version == JuiceXPC.protocolVersion) ? .ready : .versionMismatch
        } catch {
            state = .unavailable
        }
        return state
    }

    /// Fetches all energy intervals starting at or after `since`.
    func fetchIntervals(since: Date) async throws -> [EnergyInterval] {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShot()
            guard let proxy = remoteProxy(errorHandler: { error in
                resumed.run { continuation.resume(throwing: error) }
            }) else {
                resumed.run {
                    continuation.resume(throwing: HelperError.error(
                        .internalError, message: "Failed to create helper proxy"))
                }
                return
            }
            proxy.fetchEnergyIntervals(sinceEpoch: since.timeIntervalSince1970) { data, error in
                resumed.run {
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? HelperError.error(
                            .internalError, message: "Helper returned neither data nor error"))
                    }
                }
            }
        }
        return try JSONDecoder().decode([EnergyInterval].self, from: data)
    }
}

/// Guards a continuation against double-resume: XPC can invoke both the
/// error handler and (never for the same call, but defensively) the reply.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { body() }
    }
}
