import Foundation
import Testing
@testable import Juice

@MainActor
private final class FakeChargeLimitBackend {
    private var reads: [Result<ChargeLimitConfiguration?, Error>]
    private var writes: [Result<Void, Error>]
    private(set) var readCount = 0
    private(set) var writtenLimits: [Int] = []

    init(
        reads: [Result<ChargeLimitConfiguration?, Error>],
        writes: [Result<Void, Error>] = []
    ) {
        self.reads = reads
        self.writes = writes
    }

    nonisolated var read:
        @Sendable () async throws -> ChargeLimitConfiguration?
    {
        { try await self.nextRead() }
    }

    nonisolated var write: @Sendable (Int) async throws -> Void {
        { try await self.nextWrite($0) }
    }

    private func nextRead() throws -> ChargeLimitConfiguration? {
        readCount += 1
        guard !reads.isEmpty else { throw TestFailure.noQueuedRead }
        let result = reads.count == 1 ? reads[0] : reads.removeFirst()
        return try result.get()
    }

    private func nextWrite(_ limit: Int) throws {
        writtenLimits.append(limit)
        guard !writes.isEmpty else { throw TestFailure.noQueuedWrite }
        try writes.removeFirst().get()
    }
}

private final class GatedChargeLimitWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedLimits: [Int] = []
    private var result: Result<Void, Error>?
    private var writer: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    var write: @Sendable (Int) async throws -> Void {
        { try await self.perform($0) }
    }

    var limits: [Int] { lock.withLock { receivedLimits } }

    func waitForWrite() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard receivedLimits.isEmpty else {
                lock.unlock()
                continuation.resume()
                return
            }
            arrival = continuation
            lock.unlock()
        }
    }

    func release(with result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        let waiting = writer
        writer = nil
        lock.unlock()
        waiting?.resume()
    }

    private func perform(_ limit: Int) async throws {
        let arrived = lock.withLock {
            receivedLimits.append(limit)
            defer { arrival = nil }
            return arrival
        }
        arrived?.resume()

        await withCheckedContinuation { continuation in
            let alreadyReleased = lock.withLock {
                guard result == nil else { return true }
                writer = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }

        try lock.withLock { result! }.get()
    }
}

/// Parks one selected read so a stale refresh can finish after a newer write.
private final class GatedChargeLimitReader: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ChargeLimitConfiguration?, Error>]
    private let gatedCall: Int
    private var callCount = 0
    private var released = false
    private var reader: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(
        results: [Result<ChargeLimitConfiguration?, Error>],
        gatedCall: Int
    ) {
        self.results = results
        self.gatedCall = gatedCall
    }

    var read: @Sendable () async throws -> ChargeLimitConfiguration? {
        { try await self.next() }
    }

    func waitForGatedRead() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard callCount < gatedCall else {
                lock.unlock()
                continuation.resume()
                return
            }
            arrival = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiting = reader
        reader = nil
        lock.unlock()
        waiting?.resume()
    }

    private func next() async throws -> ChargeLimitConfiguration? {
        let (shouldWait, result, arrived) = lock.withLock {
            callCount += 1
            let shouldWait = callCount == gatedCall
            let result = results.count > 1 ? results.removeFirst() : results[0]
            let arrived = shouldWait ? arrival : nil
            if shouldWait { arrival = nil }
            return (shouldWait, result, arrived)
        }
        arrived?.resume()

        if shouldWait {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !released else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                reader = continuation
                lock.unlock()
            }
        }
        return try result.get()
    }
}

@MainActor
@Suite("Charge Limit controller")
struct ChargeLimitControllerTests {
    @Test("Refresh publishes the persistent limit and available choices")
    func refreshAvailable() async {
        let backend = FakeChargeLimitBackend(reads: [
            .success(Self.configuration(90))
        ])
        let controller = Self.controller(backend)

        #expect(controller.status == .loading)
        await controller.refresh()

        #expect(controller.status == .available(Self.configuration(90)))
        #expect(controller.displayedLimit == 90)
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("Temporary Charge to Full remains distinct from a persistent 100 percent limit")
    func temporaryOverride() async {
        let temporary = Self.configuration(100, temporarilyOverridden: true)
        let backend = FakeChargeLimitBackend(reads: [.success(temporary)])
        let controller = Self.controller(backend)

        await controller.refresh()

        #expect(controller.status == .available(temporary))
        #expect(controller.status.configuration?.selection == .chargingToFull)
        #expect(controller.displayedLimit == nil)
    }

    @Test("Choosing 100 during Charge to Full persists it instead of no-oping")
    func temporaryOverrideCanBecomePersistent100() async {
        let backend = FakeChargeLimitBackend(
            reads: [
                .success(Self.configuration(100, temporarilyOverridden: true)),
                .success(Self.configuration(100)),
            ],
            writes: [.success(())])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setLimit(100)

        #expect(backend.writtenLimits == [100])
        #expect(controller.status == .available(Self.configuration(100)))
        #expect(controller.displayedLimit == 100)
    }

    @Test("Unsupported and unreadable machines fail closed")
    func unavailableStates() async {
        let unsupportedBackend = FakeChargeLimitBackend(reads: [.success(nil)])
        let unsupported = Self.controller(unsupportedBackend)
        await unsupported.refresh()
        #expect(unsupported.status == .unsupported)

        let failedBackend = FakeChargeLimitBackend(reads: [
            .failure(TestFailure.expected)
        ])
        let failed = Self.controller(failedBackend)
        await failed.refresh()
        #expect(failed.status == .unavailable)
    }

    @Test("A write is verified by re-reading macOS")
    func successfulWrite() async {
        let backend = FakeChargeLimitBackend(
            reads: [
                .success(Self.configuration(100)),
                .success(Self.configuration(80)),
            ],
            writes: [.success(())])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setLimit(80)

        #expect(backend.writtenLimits == [80])
        #expect(controller.status == .available(Self.configuration(80)))
        #expect(controller.displayedLimit == 80)
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("Current and unavailable choices never invoke the writer")
    func rejectedNoOpWrites() async {
        let backend = FakeChargeLimitBackend(reads: [
            .success(Self.configuration(90))
        ])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setLimit(90)
        await controller.setLimit(75)

        #expect(backend.writtenLimits.isEmpty)
        #expect(controller.status == .available(Self.configuration(90)))
    }

    @Test("A failed write restores the authoritative limit and reports failure")
    func failedWriteReconciles() async {
        let backend = FakeChargeLimitBackend(
            reads: [
                .success(Self.configuration(90)),
                .success(Self.configuration(90)),
            ],
            writes: [.failure(TestFailure.expected)])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setLimit(80)

        #expect(controller.status == .available(Self.configuration(90)))
        #expect(controller.lastErrorMessage ==
            "Charge Limit could not be changed.")
    }

    @Test("A thrown write that landed is accepted after reconciliation")
    func raceErrorUsesEffectiveState() async {
        let backend = FakeChargeLimitBackend(
            reads: [
                .success(Self.configuration(90)),
                .success(Self.configuration(80)),
            ],
            writes: [.failure(TestFailure.expected)])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setLimit(80)

        #expect(controller.status == .available(Self.configuration(80)))
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("A second selection is ignored while the first write is in flight")
    func writesAreCoalesced() async {
        let initial = Self.configuration(100)
        let backend = FakeChargeLimitBackend(reads: [
            .success(initial),
            .success(Self.configuration(80)),
        ])
        let writer = GatedChargeLimitWriter()
        let controller = ChargeLimitController(
            readConfiguration: backend.read,
            writeLimit: writer.write)
        await controller.refresh()

        let first = Task { await controller.setLimit(80) }
        await writer.waitForWrite()
        #expect(controller.isWriting)
        #expect(controller.pendingLimit == 80)

        await controller.setLimit(85)
        #expect(writer.limits == [80])

        writer.release(with: .success(()))
        await first.value
        #expect(controller.status == .available(Self.configuration(80)))
    }

    @Test("A stale refresh cannot roll back a newer verified write")
    func staleRefreshIsDiscarded() async {
        let reader = GatedChargeLimitReader(
            results: [
                .success(Self.configuration(90)),
                .success(Self.configuration(90)),
                .success(Self.configuration(80)),
            ],
            gatedCall: 2)
        let backend = FakeChargeLimitBackend(
            reads: [],
            writes: [.success(())])
        let controller = ChargeLimitController(
            readConfiguration: reader.read,
            writeLimit: backend.write)
        await controller.refresh()

        let staleRefresh = Task { await controller.refresh() }
        await reader.waitForGatedRead()
        await controller.setLimit(80)
        reader.release()
        await staleRefresh.value

        #expect(controller.status == .available(Self.configuration(80)))
    }

    @Test("Cancellation before setter entry performs no write")
    func cancellationBeforeWrite() async {
        let backend = FakeChargeLimitBackend(reads: [
            .success(Self.configuration(90))
        ])
        let controller = Self.controller(backend)
        await controller.refresh()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.setLimit(80)
        }
        await task.value

        #expect(backend.writtenLimits.isEmpty)
        #expect(controller.status == .available(Self.configuration(90)))
        #expect(!controller.isWriting)
        #expect(controller.pendingLimit == nil)
    }

    @Test("Cancellation after setter entry reconciles the authoritative result")
    func cancellationAfterWrite() async {
        let backend = FakeChargeLimitBackend(reads: [
            .success(Self.configuration(90)),
            .success(Self.configuration(80)),
        ])
        let writer = GatedChargeLimitWriter()
        let controller = ChargeLimitController(
            readConfiguration: backend.read,
            writeLimit: writer.write)
        await controller.refresh()

        let task = Task { await controller.setLimit(80) }
        await writer.waitForWrite()
        task.cancel()
        writer.release(with: .success(()))
        await task.value

        #expect(writer.limits == [80])
        #expect(controller.status == .available(Self.configuration(80)))
        #expect(controller.lastErrorMessage == nil)
        #expect(!controller.isWriting)
        #expect(controller.pendingLimit == nil)
    }

    @Test("The newest of two overlapping refreshes wins")
    func newestRefreshWins() async {
        let reader = GatedChargeLimitReader(
            results: [
                .success(Self.configuration(90)),
                .success(Self.configuration(80)),
            ],
            gatedCall: 1)
        let controller = ChargeLimitController(
            readConfiguration: reader.read,
            writeLimit: { _ in })

        let staleRefresh = Task { await controller.refresh() }
        await reader.waitForGatedRead()
        await controller.refresh()
        reader.release()
        await staleRefresh.value

        #expect(controller.status == .available(Self.configuration(80)))
    }

    @Test("Battery Settings action uses the injected opener")
    func openBatterySettings() {
        var openCount = 0
        let controller = ChargeLimitController(
            readConfiguration: { nil },
            writeLimit: { _ in },
            openBatterySettingsAction: { openCount += 1 })

        controller.openBatterySettings()

        #expect(openCount == 1)
    }

    private static func controller(
        _ backend: FakeChargeLimitBackend
    ) -> ChargeLimitController {
        ChargeLimitController(
            readConfiguration: backend.read,
            writeLimit: backend.write)
    }

    private static func configuration(
        _ currentLimit: Int,
        temporarilyOverridden: Bool = false
    ) -> ChargeLimitConfiguration {
        ChargeLimitConfiguration(
            selection: temporarilyOverridden
                ? .chargingToFull
                : .persistent(currentLimit),
            availableLimits: [80, 85, 90, 95, 100])
    }
}

private enum TestFailure: Error {
    case expected
    case noQueuedRead
    case noQueuedWrite
}
