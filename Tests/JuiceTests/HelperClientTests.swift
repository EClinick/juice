import Foundation
import Testing
import JuiceXPCShared
@testable import Juice

@Suite("Helper client protocol caching")
struct HelperClientTests {
    @Test("Repeated live samples reuse one successful handshake")
    func liveSamplesReuseHandshake() async throws {
        let helper = MockHelper(protocolVersion: 3)
        let connection = MockHelperConnection(helper: helper)
        let client = makeClient(connections: [connection])

        _ = try await client.fetchLiveEnergySample()
        _ = try await client.fetchLiveEnergySample()

        #expect(helper.handshakeCount == 1)
        #expect(helper.liveSampleCount == 2)
    }

    @Test("Battery and live methods share the connection protocol cache")
    func versionedMethodsShareHandshake() async throws {
        let helper = MockHelper(protocolVersion: 3)
        let connection = MockHelperConnection(helper: helper)
        let client = makeClient(connections: [connection])

        _ = try await client.fetchBatteryLevels(since: .distantPast)
        _ = try await client.fetchLiveEnergySample()

        #expect(helper.handshakeCount == 1)
        #expect(helper.batteryLevelCount == 1)
        #expect(helper.liveSampleCount == 1)
    }

    @Test("Compatibility gates never invoke methods missing from an older helper")
    func olderHelperIsGated() async throws {
        let helper = MockHelper(protocolVersion: 2)
        let connection = MockHelperConnection(helper: helper)
        let client = makeClient(connections: [connection])

        _ = try await client.fetchBatteryLevels(since: .distantPast)
        await expectHelperOutdated {
            try await client.fetchLiveEnergySample()
        }

        #expect(helper.handshakeCount == 1)
        #expect(helper.batteryLevelCount == 1)
        #expect(helper.liveSampleCount == 0)
    }

    @Test("checkState performs a fresh handshake and recovers a helper upgrade")
    func checkStateRefreshesCachedVersion() async throws {
        let helper = MockHelper(protocolVersion: 2)
        let connection = MockHelperConnection(helper: helper)
        let client = makeClient(connections: [connection])

        await expectHelperOutdated {
            try await client.fetchLiveEnergySample()
        }
        helper.protocolVersion = 3

        // The old answer remains connection-scoped until an explicit state
        // check or a connection lifecycle event requires revalidation.
        await expectHelperOutdated {
            try await client.fetchLiveEnergySample()
        }
        #expect(helper.handshakeCount == 1)

        let state = await client.checkState()
        guard case .ready = state else {
            Issue.record("Expected upgraded helper to become ready")
            return
        }
        _ = try await client.fetchLiveEnergySample()

        #expect(helper.handshakeCount == 2)
        #expect(helper.liveSampleCount == 1)
    }

    @Test("checkState ignores a reply from an invalidated connection")
    func checkStateRetriesAStaleReply() async {
        let firstHelper = MockHelper(
            protocolVersion: JuiceXPC.protocolVersion + 1)
        let secondHelper = MockHelper(protocolVersion: JuiceXPC.protocolVersion)
        let firstConnection = MockHelperConnection(helper: firstHelper)
        let secondConnection = MockHelperConnection(helper: secondHelper)
        let client = makeClient(connections: [firstConnection, secondConnection])
        firstHelper.beforeHandshakeReply = {
            firstConnection.invalidateFromRemote()
        }

        let state = await client.checkState()

        guard case .ready = state else {
            Issue.record("Expected replacement helper to be ready")
            return
        }
        #expect(firstHelper.handshakeCount == 1)
        #expect(secondHelper.handshakeCount == 1)
    }

    @Test("An interruption clears the cache on the retained connection")
    func interruptionRequiresRevalidation() async throws {
        let helper = MockHelper(protocolVersion: 3)
        let connection = MockHelperConnection(helper: helper)
        let client = makeClient(connections: [connection])

        _ = try await client.fetchLiveEnergySample()
        connection.interrupt()
        _ = try await client.fetchLiveEnergySample()

        #expect(helper.handshakeCount == 2)
        #expect(helper.liveSampleCount == 2)
    }

    @Test("An XPC proxy error clears the cached handshake")
    func proxyErrorRequiresRevalidation() async throws {
        let helper = MockHelper(protocolVersion: 3)
        let connection = MockHelperConnection(helper: helper)
        let client = makeClient(connections: [connection])

        _ = try await client.fetchLiveEnergySample()
        connection.fail(TestConnectionError.expected)
        _ = try await client.fetchLiveEnergySample()

        #expect(helper.handshakeCount == 2)
        #expect(helper.liveSampleCount == 2)
    }

    @Test("Invalidation builds and validates a replacement connection")
    func invalidationUsesReplacementConnection() async throws {
        let firstHelper = MockHelper(protocolVersion: 3)
        let secondHelper = MockHelper(protocolVersion: 3)
        let firstConnection = MockHelperConnection(helper: firstHelper)
        let secondConnection = MockHelperConnection(helper: secondHelper)
        let client = makeClient(connections: [firstConnection, secondConnection])

        _ = try await client.fetchLiveEnergySample()
        firstConnection.invalidateFromRemote()
        _ = try await client.fetchLiveEnergySample()

        #expect(firstHelper.handshakeCount == 1)
        #expect(firstHelper.liveSampleCount == 1)
        #expect(secondHelper.handshakeCount == 1)
        #expect(secondHelper.liveSampleCount == 1)
        #expect(firstConnection.resumeCount == 1)
        #expect(secondConnection.resumeCount == 1)
    }

    @Test("A replacement between handshake and dispatch is revalidated")
    func replacementDuringValidationUsesReplacementVersion() async {
        let firstHelper = MockHelper(protocolVersion: 3)
        let secondHelper = MockHelper(protocolVersion: 2)
        let firstConnection = MockHelperConnection(helper: firstHelper)
        let secondConnection = MockHelperConnection(helper: secondHelper)
        let client = makeClient(connections: [firstConnection, secondConnection])
        firstHelper.beforeHandshakeReply = {
            firstConnection.invalidateFromRemote()
        }

        await expectHelperOutdated {
            try await client.fetchLiveEnergySample()
        }

        #expect(firstHelper.handshakeCount == 1)
        #expect(firstHelper.liveSampleCount == 0)
        #expect(secondHelper.handshakeCount == 1)
        #expect(secondHelper.liveSampleCount == 0)
    }

    @Test("A missing handshake reply still enforces the request timeout")
    func handshakeTimeoutIsPreserved() async {
        let helper = MockHelper(protocolVersion: 3, repliesToHandshake: false)
        let connection = MockHelperConnection(helper: helper)
        let factory = MockConnectionFactory([connection])
        let client = HelperClient(
            makeConnection: { factory.next() },
            requestTimeout: 0.01,
            connectionFailureReporter: {})

        do {
            _ = try await client.fetchLiveEnergySample()
            Issue.record("Expected timedOut")
        } catch HelperClientError.timedOut {
            // Expected.
        } catch {
            Issue.record("Expected timedOut, got \(error)")
        }

        #expect(helper.handshakeCount == 1)
        #expect(helper.liveSampleCount == 0)
        #expect(connection.invalidateCount == 1)
    }

    @Test("Successful replies cancel their pending timeout")
    func successfulReplyCancelsTimeout() async throws {
        let helper = MockHelper(protocolVersion: 3)
        let connection = MockHelperConnection(helper: helper)
        let factory = MockConnectionFactory([connection])
        let client = HelperClient(
            makeConnection: { factory.next() },
            requestTimeout: 0.01,
            connectionFailureReporter: {})

        _ = try await client.fetchLiveEnergySample()
        try await Task.sleep(for: .milliseconds(30))
        _ = try await client.fetchLiveEnergySample()

        #expect(helper.handshakeCount == 1)
        #expect(helper.liveSampleCount == 2)
        #expect(connection.invalidateCount == 0)
    }

    @Test("A fetch timeout discards its validated connection")
    func fetchTimeoutUsesReplacementConnection() async throws {
        let firstHelper = MockHelper(
            protocolVersion: 3,
            repliesToLiveSample: false)
        let secondHelper = MockHelper(protocolVersion: 3)
        let firstConnection = MockHelperConnection(helper: firstHelper)
        let secondConnection = MockHelperConnection(helper: secondHelper)
        let factory = MockConnectionFactory([firstConnection, secondConnection])
        let client = HelperClient(
            makeConnection: { factory.next() },
            requestTimeout: 0.01,
            connectionFailureReporter: {})

        do {
            _ = try await client.fetchLiveEnergySample()
            Issue.record("Expected timedOut")
        } catch HelperClientError.timedOut {
            // Expected.
        } catch {
            Issue.record("Expected timedOut, got \(error)")
        }
        _ = try await client.fetchLiveEnergySample()

        #expect(firstHelper.handshakeCount == 1)
        #expect(firstHelper.liveSampleCount == 1)
        #expect(firstConnection.invalidateCount == 1)
        #expect(secondHelper.handshakeCount == 1)
        #expect(secondHelper.liveSampleCount == 1)
    }

    private func makeClient(
        connections: [MockHelperConnection]
    ) -> HelperClient {
        let factory = MockConnectionFactory(connections)
        return HelperClient(
            makeConnection: { factory.next() },
            connectionFailureReporter: {})
    }

    private func expectHelperOutdated<T>(
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected helperOutdated")
        } catch HelperClientError.helperOutdated {
            // Expected.
        } catch {
            Issue.record("Expected helperOutdated, got \(error)")
        }
    }
}

private enum TestConnectionError: Error {
    case expected
}

private final class MockConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [MockHelperConnection]

    init(_ connections: [MockHelperConnection]) {
        self.connections = connections
    }

    func next() -> MockHelperConnection {
        lock.lock()
        defer { lock.unlock() }
        guard !connections.isEmpty else {
            Issue.record("HelperClient requested an unexpected connection")
            return MockHelperConnection(helper: MockHelper(protocolVersion: 3))
        }
        return connections.removeFirst()
    }
}

private final class MockHelperConnection: HelperClientConnection, @unchecked Sendable {
    var invalidationHandler: (() -> Void)?
    var interruptionHandler: (() -> Void)?

    private let lock = NSLock()
    private let helper: HelperProtocol
    private var errorHandler: ((Error) -> Void)?
    private(set) var resumeCount = 0
    private(set) var invalidateCount = 0

    init(helper: HelperProtocol) {
        self.helper = helper
    }

    func resume() {
        lock.lock()
        resumeCount += 1
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidateCount += 1
        lock.unlock()
    }

    func remoteObjectProxyWithErrorHandler(
        _ handler: @escaping (Error) -> Void
    ) -> HelperProtocol? {
        lock.lock()
        errorHandler = handler
        lock.unlock()
        return helper
    }

    func interrupt() {
        interruptionHandler?()
    }

    func invalidateFromRemote() {
        invalidationHandler?()
    }

    func fail(_ error: Error) {
        lock.lock()
        let handler = errorHandler
        lock.unlock()
        handler?(error)
    }
}

private final class MockHelper: NSObject, HelperProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _protocolVersion: Int
    private let repliesToHandshake: Bool
    private let repliesToLiveSample: Bool
    private var _beforeHandshakeReply: (() -> Void)?
    private var _handshakeCount = 0
    private var _batteryLevelCount = 0
    private var _liveSampleCount = 0

    var protocolVersion: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _protocolVersion
        }
        set {
            lock.lock()
            _protocolVersion = newValue
            lock.unlock()
        }
    }

    var beforeHandshakeReply: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _beforeHandshakeReply
        }
        set {
            lock.lock()
            _beforeHandshakeReply = newValue
            lock.unlock()
        }
    }

    var handshakeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _handshakeCount
    }

    var batteryLevelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _batteryLevelCount
    }

    var liveSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _liveSampleCount
    }

    init(
        protocolVersion: Int,
        repliesToHandshake: Bool = true,
        repliesToLiveSample: Bool = true
    ) {
        _protocolVersion = protocolVersion
        self.repliesToHandshake = repliesToHandshake
        self.repliesToLiveSample = repliesToLiveSample
    }

    func handshake(reply: @escaping (Int, String) -> Void) {
        lock.lock()
        _handshakeCount += 1
        let version = _protocolVersion
        let beforeReply = _beforeHandshakeReply
        _beforeHandshakeReply = nil
        lock.unlock()
        if repliesToHandshake {
            beforeReply?()
            reply(version, "mock-helper")
        }
    }

    func fetchEnergyIntervals(
        sinceEpoch: Double,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        reply(try! JSONEncoder().encode([EnergyInterval]()), nil)
    }

    func fetchBatteryLevels(
        sinceEpoch: Double,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        lock.lock()
        _batteryLevelCount += 1
        lock.unlock()
        reply(try! JSONEncoder().encode([BatteryLevelPoint]()), nil)
    }

    func fetchLiveEnergySample(
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        lock.lock()
        _liveSampleCount += 1
        lock.unlock()
        if repliesToLiveSample {
            let snapshot = LiveEnergySnapshot(timestampEpoch: 1, samples: [])
            reply(try! JSONEncoder().encode(snapshot), nil)
        }
    }
}
