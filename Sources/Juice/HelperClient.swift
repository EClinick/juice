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

/// Typed errors raised by ``HelperClient`` itself (as opposed to errors
/// forwarded from the helper, which use the `HelperError` domain).
enum HelperClientError: Error {
    /// The installed helper predates the requested capability. Callers that
    /// can live without the data (e.g. backfill) should skip silently.
    case helperOutdated
}

/// Wraps the NSXPCConnection to the privileged helper with async APIs.
final class HelperClient {
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    /// Last known helper state, updated by ``checkState()``.
    /// The backing storage is protected by ``lock`` because it is written
    /// from XPC callback queues.
    private var _state: HelperState = .unavailable
    private(set) var state: HelperState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _state
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _state = newValue
        }
    }

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
    ///
    /// Protocol versions above 1 only add methods, so any helper from 1 up
    /// to the app's own version is compatible; methods added later gate on
    /// the handshake version themselves (see ``fetchBatteryLevels(since:)``).
    /// Only a helper newer than the app is a mismatch.
    @discardableResult
    func checkState() async -> HelperState {
        do {
            let (version, _) = try await handshake()
            state = (1...JuiceXPC.protocolVersion).contains(version)
                ? .ready : .versionMismatch
        } catch {
            state = .unavailable
        }
        return state
    }

    /// Fetches all energy intervals starting at or after `since`.
    func fetchIntervals(since: Date) async throws -> [EnergyInterval] {
        let data = try await fetchData { proxy, reply in
            proxy.fetchEnergyIntervals(sinceEpoch: since.timeIntervalSince1970, reply: reply)
        }
        return try JSONDecoder().decode([EnergyInterval].self, from: data)
    }

    /// Fetches all battery-level history points at or after `since`.
    ///
    /// The battery-level query was added in protocol version 2. Against an
    /// older installed helper this throws ``HelperClientError/helperOutdated``
    /// without ever invoking the unknown method, so the app keeps working
    /// until the user upgrades the helper.
    func fetchBatteryLevels(since: Date) async throws -> [BatteryLevelPoint] {
        let (version, _) = try await handshake()
        guard version >= 2 else { throw HelperClientError.helperOutdated }
        let data = try await fetchData { proxy, reply in
            proxy.fetchBatteryLevels(sinceEpoch: since.timeIntervalSince1970, reply: reply)
        }
        return try JSONDecoder().decode([BatteryLevelPoint].self, from: data)
    }

    /// Shared continuation plumbing for the (Data?, NSError?) fetch methods.
    private func fetchData(
        _ invoke: @escaping (HelperProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
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
            invoke(proxy) { data, error in
                resumed.run {
                    // The protocol guarantees exactly one of (data, error) is
                    // set. Anything else is a protocol violation we must not
                    // silently accept.
                    switch (data, error) {
                    case let (data?, nil):
                        continuation.resume(returning: data)
                    case let (nil, error?):
                        continuation.resume(throwing: error)
                    default:
                        continuation.resume(throwing: HelperError.error(
                            .internalError,
                            message: "Helper reply violated protocol: expected exactly one of data or error"))
                    }
                }
            }
        }
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
