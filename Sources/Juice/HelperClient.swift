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
enum HelperClientError: LocalizedError {
    /// The installed helper predates the requested capability. Callers that
    /// can live without the data (e.g. backfill) should skip silently.
    case helperOutdated
    /// The daemon accepted a connection but did not answer in time.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperOutdated: return "The installed helper is too old."
        case .timedOut: return "The helper did not respond in time."
        }
    }
}

/// Wraps the NSXPCConnection to the privileged helper with async APIs.
final class HelperClient: @unchecked Sendable {
    private struct ConnectionContext {
        let connection: any HelperClientConnection
        let generation: UInt64
    }

    private struct HandshakeCache {
        let connection: any HelperClientConnection
        let generation: UInt64
        let value: (Int, String)
    }

    private var connection: (any HelperClientConnection)?
    private var connectionGeneration: UInt64 = 0
    private var handshakeCache: HandshakeCache?
    private let lock = NSLock()
    private let makeConnection: () -> any HelperClientConnection
    private let requestTimeout: TimeInterval
    private let connectionFailureReporter: () -> Void

    init(
        makeConnection: @escaping () -> any HelperClientConnection = {
            XPCClientConnection()
        },
        requestTimeout: TimeInterval = 12,
        connectionFailureReporter: @escaping () -> Void = {
            Task { @MainActor in
                HelperRegistrationController.shared.refresh()
            }
        }
    ) {
        self.makeConnection = makeConnection
        self.requestTimeout = requestTimeout
        self.connectionFailureReporter = connectionFailureReporter
    }

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

    private func currentConnection() -> ConnectionContext {
        lock.lock()
        defer { lock.unlock() }

        if let connection {
            return ConnectionContext(
                connection: connection,
                generation: connectionGeneration)
        }

        let newConnection = makeConnection()
        connectionGeneration &+= 1
        handshakeCache = nil
        let weakConnection = WeakHelperClientConnection(newConnection)
        newConnection.invalidationHandler = { [weak self] in
            // The helper is gone (uninstalled or denied); drop the connection
            // so the next call builds a fresh one instead of failing forever.
            guard let invalidatedConnection = weakConnection.value else { return }
            self?.dropConnection(expected: invalidatedConnection)
            self?.reportConnectionFailure()
        }
        newConnection.interruptionHandler = { [weak self] in
            // The helper crashed or was killed; launchd relaunches it on the
            // next message, so keeping the connection is fine. Its cached
            // protocol version is not: a newly launched helper may differ.
            NSLog("Juice: helper connection interrupted")
            guard let interruptedConnection = weakConnection.value else { return }
            self?.clearHandshakeCache(expected: interruptedConnection)
            self?.reportConnectionFailure()
        }
        newConnection.resume()
        connection = newConnection
        return ConnectionContext(
            connection: newConnection,
            generation: connectionGeneration)
    }

    private func dropConnection(expected: any HelperClientConnection) {
        lock.lock()
        defer { lock.unlock() }
        if connection === expected {
            connection = nil
            handshakeCache = nil
            connectionGeneration &+= 1
        }
    }

    private func clearHandshakeCache(expected: any HelperClientConnection) {
        lock.lock()
        defer { lock.unlock() }
        if connection === expected {
            handshakeCache = nil
            connectionGeneration &+= 1
        }
    }

    private func clearHandshakeCache(
        for context: ConnectionContext,
        settingState newState: HelperState? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard
            connection === context.connection,
            connectionGeneration == context.generation
        else {
            return
        }
        handshakeCache = nil
        connectionGeneration &+= 1
        if let newState {
            _state = newState
        }
    }

    private func cachedHandshake(for context: ConnectionContext) -> (Int, String)? {
        lock.lock()
        defer { lock.unlock() }
        guard
            connection === context.connection,
            connectionGeneration == context.generation,
            let handshakeCache,
            handshakeCache.connection === context.connection,
            handshakeCache.generation == context.generation
        else {
            return nil
        }
        return handshakeCache.value
    }

    private func storeHandshake(
        _ value: (Int, String),
        for context: ConnectionContext
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard
            connection === context.connection,
            connectionGeneration == context.generation
        else {
            return
        }
        handshakeCache = HandshakeCache(
            connection: context.connection,
            generation: context.generation,
            value: value)
    }

    private func isCurrent(_ context: ConnectionContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection === context.connection
            && connectionGeneration == context.generation
    }

    private func setState(
        _ newState: HelperState,
        ifCurrent context: ConnectionContext
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard
            connection === context.connection,
            connectionGeneration == context.generation
        else {
            return false
        }
        _state = newState
        return true
    }

    private func remoteProxy(
        on context: ConnectionContext,
        errorHandler: @escaping (Error) -> Void
    ) -> HelperProtocol? {
        context.connection.remoteObjectProxyWithErrorHandler(errorHandler)
    }

    // MARK: - Async API

    /// Performs the version handshake with the helper.
    /// Returns (protocol version, helper version string).
    func handshake() async throws -> (Int, String) {
        let context = currentConnection()
        return try await performHandshake(on: context)
    }

    /// Returns the protocol version already validated for the current
    /// connection, handshaking only when this connection has not succeeded
    /// before (or was interrupted and therefore needs revalidation).
    private func validatedHandshake() async throws -> (
        value: (Int, String),
        context: ConnectionContext
    ) {
        let context = currentConnection()
        if let cached = cachedHandshake(for: context) {
            return (cached, context)
        }
        return (try await performHandshake(on: context), context)
    }

    private func performHandshake(
        on context: ConnectionContext,
        failureState: HelperState? = nil
    ) async throws -> (Int, String) {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShot()
            guard let proxy = remoteProxy(on: context, errorHandler: { error in
                self.clearHandshakeCache(
                    for: context,
                    settingState: failureState)
                self.reportConnectionFailure()
                resumed.run { continuation.resume(throwing: error) }
            }) else {
                clearHandshakeCache(
                    for: context,
                    settingState: failureState)
                resumed.run {
                    continuation.resume(throwing: HelperError.error(
                        .internalError, message: "Failed to create helper proxy"))
                }
                return
            }
            resumed.armTimeout(after: requestTimeout) { [weak self] in
                self?.invalidateConnection(
                    context: context,
                    settingState: failureState)
                self?.reportConnectionFailure()
                continuation.resume(throwing: HelperClientError.timedOut)
            }
            proxy.handshake { version, helperVersion in
                resumed.run {
                    let value = (version, helperVersion)
                    self.storeHandshake(value, for: context)
                    continuation.resume(returning: value)
                }
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
        // A reply can race an invalidation. Never publish state from an old
        // connection; retry once so the result describes its replacement.
        for _ in 0..<2 {
            let context = currentConnection()
            do {
                let (version, _) = try await performHandshake(
                    on: context,
                    failureState: .unavailable)
                let newState: HelperState =
                    (1...JuiceXPC.protocolVersion).contains(version)
                    ? .ready : .versionMismatch
                guard setState(newState, ifCurrent: context) else { continue }
                return newState
            } catch {
                // The failure may arrive after this connection was replaced
                // and a newer check published its state. Retry against the
                // replacement instead of overwriting that newer result.
                guard setState(.unavailable, ifCurrent: context) else { continue }
                return .unavailable
            }
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
        let data = try await fetchData(requiringProtocolVersion: 2) { proxy, reply in
            proxy.fetchBatteryLevels(sinceEpoch: since.timeIntervalSince1970, reply: reply)
        }
        return try JSONDecoder().decode([BatteryLevelPoint].self, from: data)
    }

    /// Fetches one raw live-energy snapshot: cumulative per-process counters at
    /// the instant of the call. The app differentiates consecutive snapshots to
    /// compute watts.
    ///
    /// Added in protocol version 3. Against an older installed helper this
    /// throws ``HelperClientError/helperOutdated`` without ever invoking the
    /// unknown method, exactly like ``fetchBatteryLevels(since:)``.
    func fetchLiveEnergySample() async throws -> LiveEnergySnapshot {
        let data = try await fetchData(requiringProtocolVersion: 3) { proxy, reply in
            proxy.fetchLiveEnergySample(reply: reply)
        }
        return try JSONDecoder().decode(LiveEnergySnapshot.self, from: data)
    }

    /// Gates a versioned method on a handshake cached for the exact connection
    /// that will carry the request. If that connection changes between
    /// validation and dispatch, retry validation once on the replacement.
    private func fetchData(
        requiringProtocolVersion minimumVersion: Int,
        _ invoke: @escaping (HelperProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
        for _ in 0..<2 {
            let validation = try await validatedHandshake()
            guard isCurrent(validation.context) else { continue }
            guard validation.value.0 >= minimumVersion else {
                throw HelperClientError.helperOutdated
            }
            return try await fetchData(on: validation.context, invoke)
        }
        throw HelperError.error(
            .internalError,
            message: "Helper connection changed while validating its protocol version")
    }

    /// Shared continuation plumbing for the (Data?, NSError?) fetch methods.
    private func fetchData(
        _ invoke: @escaping (HelperProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
        try await fetchData(on: currentConnection(), invoke)
    }

    private func fetchData(
        on context: ConnectionContext,
        _ invoke: @escaping (HelperProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShot()
            guard let proxy = remoteProxy(on: context, errorHandler: { error in
                self.clearHandshakeCache(expected: context.connection)
                self.reportConnectionFailure()
                resumed.run { continuation.resume(throwing: error) }
            }) else {
                clearHandshakeCache(expected: context.connection)
                resumed.run {
                    continuation.resume(throwing: HelperError.error(
                        .internalError, message: "Failed to create helper proxy"))
                }
                return
            }
            resumed.armTimeout(after: requestTimeout) { [weak self] in
                self?.invalidateConnection(expected: context.connection)
                self?.reportConnectionFailure()
                continuation.resume(throwing: HelperClientError.timedOut)
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

    private func invalidateConnection(
        context: ConnectionContext,
        settingState newState: HelperState? = nil
    ) {
        lock.lock()
        let oldConnection: (any HelperClientConnection)?
        if connection === context.connection,
           connectionGeneration == context.generation {
            oldConnection = connection
            connection = nil
            handshakeCache = nil
            connectionGeneration &+= 1
            if let newState {
                _state = newState
            }
        } else {
            oldConnection = nil
        }
        lock.unlock()
        oldConnection?.invalidate()
    }

    private func invalidateConnection(expected: any HelperClientConnection) {
        lock.lock()
        let oldConnection: (any HelperClientConnection)?
        if connection === expected {
            oldConnection = connection
            connection = nil
            handshakeCache = nil
            connectionGeneration &+= 1
        } else {
            oldConnection = nil
        }
        lock.unlock()
        oldConnection?.invalidate()
    }

    private func reportConnectionFailure() {
        connectionFailureReporter()
    }
}

/// Narrow connection seam used by ``HelperClient``. Tests can exercise cache
/// invalidation and protocol gating without contacting a privileged daemon.
protocol HelperClientConnection: AnyObject {
    var invalidationHandler: (() -> Void)? { get set }
    var interruptionHandler: (() -> Void)? { get set }

    func resume()
    func invalidate()
    func remoteObjectProxyWithErrorHandler(
        _ handler: @escaping (Error) -> Void
    ) -> HelperProtocol?
}

private final class XPCClientConnection: HelperClientConnection {
    private let connection: NSXPCConnection

    var invalidationHandler: (() -> Void)? {
        get { connection.invalidationHandler }
        set { connection.invalidationHandler = newValue }
    }

    var interruptionHandler: (() -> Void)? {
        get { connection.interruptionHandler }
        set { connection.interruptionHandler = newValue }
    }

    init() {
        connection = NSXPCConnection(
            machServiceName: JuiceXPC.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    }

    func resume() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func remoteObjectProxyWithErrorHandler(
        _ handler: @escaping (Error) -> Void
    ) -> HelperProtocol? {
        connection.remoteObjectProxyWithErrorHandler(handler) as? HelperProtocol
    }
}

private final class WeakHelperClientConnection: @unchecked Sendable {
    weak var value: (any HelperClientConnection)?
    init(_ value: any HelperClientConnection) { self.value = value }
}

/// Guards a continuation against double-resume: XPC can invoke both the
/// error handler and (never for the same call, but defensively) the reply.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var timeout: DispatchWorkItem?

    /// Arms a cancellable timeout. A normal response or XPC error cancels the
    /// pending work item as part of winning the one-shot race.
    func armTimeout(after interval: TimeInterval, _ body: @escaping () -> Void) {
        // The work item intentionally retains the one-shot until either a
        // response cancels it or the timeout fires. Otherwise a request whose
        // transport retains neither callback could lose its timeout entirely.
        let workItem = DispatchWorkItem {
            self.run(body)
        }

        lock.lock()
        if done {
            lock.unlock()
            workItem.cancel()
            return
        }
        timeout = workItem
        lock.unlock()

        DispatchQueue.global().asyncAfter(
            deadline: .now() + interval,
            execute: workItem)
    }

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        let pendingTimeout = timeout
        timeout = nil
        lock.unlock()
        pendingTimeout?.cancel()
        if shouldRun { body() }
    }
}
