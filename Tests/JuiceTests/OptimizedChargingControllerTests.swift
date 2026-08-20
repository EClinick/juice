import Foundation
import Testing
@testable import Juice

@MainActor
private final class FakeOptimizedChargingBackend {
    private var reads: [Result<OptimizedChargingMode?, Error>]
    private var writes: [Result<Void, Error>]
    private(set) var actions: [OptimizedChargingAction] = []

    init(
        reads: [Result<OptimizedChargingMode?, Error>],
        writes: [Result<Void, Error>] = []
    ) {
        self.reads = reads
        self.writes = writes
    }

    nonisolated var read:
        @Sendable () async throws -> OptimizedChargingMode?
    {
        { try await self.nextRead() }
    }

    nonisolated var write:
        @Sendable (OptimizedChargingAction) async throws -> Void
    {
        { try await self.nextWrite($0) }
    }

    private func nextRead() throws -> OptimizedChargingMode? {
        guard !reads.isEmpty else { throw OptimizedTestFailure.noQueuedRead }
        let result = reads.count == 1 ? reads[0] : reads.removeFirst()
        return try result.get()
    }

    private func nextWrite(_ action: OptimizedChargingAction) throws {
        actions.append(action)
        guard !writes.isEmpty else {
            throw OptimizedTestFailure.noQueuedWrite
        }
        try writes.removeFirst().get()
    }
}

private final class GatedOptimizedWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedActions: [OptimizedChargingAction] = []
    private var result: Result<Void, Error>?
    private var writer: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    var write: @Sendable (OptimizedChargingAction) async throws -> Void {
        { try await self.perform($0) }
    }

    var actions: [OptimizedChargingAction] {
        lock.withLock { receivedActions }
    }

    func waitForWrite() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard receivedActions.isEmpty else {
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

    private func perform(_ action: OptimizedChargingAction) async throws {
        let arrived = lock.withLock {
            receivedActions.append(action)
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

private final class GatedOptimizedReader: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<OptimizedChargingMode?, Error>]
    private let gatedCall: Int
    private var callCount = 0
    private var released = false
    private var reader: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(
        results: [Result<OptimizedChargingMode?, Error>],
        gatedCall: Int
    ) {
        self.results = results
        self.gatedCall = gatedCall
    }

    var read: @Sendable () async throws -> OptimizedChargingMode? {
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

    private func next() async throws -> OptimizedChargingMode? {
        let (shouldWait, result, arrived) = lock.withLock {
            callCount += 1
            let shouldWait = callCount == gatedCall
            let result = results.count > 1
                ? results.removeFirst()
                : results[0]
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

private final class CrossFeatureChargingBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var limit = 100
    private var optimizedMode: OptimizedChargingMode =
        .disabledUntilTomorrow

    var readLimit:
        @Sendable () async throws -> ChargeLimitConfiguration?
    {
        {
            let limit = self.lock.withLock { self.limit }
            return ChargeLimitConfiguration(
                selection: .persistent(limit),
                availableLimits: [80, 85, 90, 95, 100])
        }
    }

    var writeLimit: @Sendable (Int) async throws -> Void {
        { requestedLimit in
            self.lock.withLock {
                self.limit = requestedLimit
                if self.optimizedMode == .disabledUntilTomorrow {
                    self.optimizedMode = .enabled
                }
            }
        }
    }

    var readOptimized:
        @Sendable () async throws -> OptimizedChargingMode?
    {
        { self.lock.withLock { self.optimizedMode } }
    }
}

@MainActor
@Suite("Optimized Battery Charging controller")
struct OptimizedChargingControllerTests {
    @Test("Refresh preserves every effective macOS state", arguments: [
        OptimizedChargingMode.disabled,
        .enabled,
        .chargingToFull,
        .disabledUntilTomorrow,
    ])
    func refresh(mode: OptimizedChargingMode) async {
        let backend = FakeOptimizedChargingBackend(reads: [.success(mode)])
        let controller = Self.controller(backend)

        await controller.refresh()

        #expect(controller.status == .available(mode))
        #expect(controller.displayedMode == mode)
    }

    @Test("Unsupported and unreadable machines fail closed")
    func unavailableStates() async {
        let unsupported = Self.controller(FakeOptimizedChargingBackend(
            reads: [.success(nil)]))
        await unsupported.refresh()
        #expect(unsupported.status == .unsupported)

        let unavailable = Self.controller(FakeOptimizedChargingBackend(
            reads: [.failure(OptimizedTestFailure.expected)]))
        await unavailable.refresh()
        #expect(unavailable.status == .unavailable)
    }

    @Test("Persistent wrappers are used from both temporary states")
    func temporaryStatesCanBecomePersistent() async {
        let fullBackend = FakeOptimizedChargingBackend(
            reads: [.success(.chargingToFull), .success(.enabled)],
            writes: [.success(())])
        let full = Self.controller(fullBackend)
        await full.refresh()
        await full.setEnabled(true)
        #expect(fullBackend.actions == [.enable])
        #expect(full.status == .available(.enabled))

        let tomorrowBackend = FakeOptimizedChargingBackend(
            reads: [
                .success(.disabledUntilTomorrow),
                .success(.disabled),
            ],
            writes: [.success(())])
        let tomorrow = Self.controller(tomorrowBackend)
        await tomorrow.refresh()
        await tomorrow.setEnabled(false)
        #expect(tomorrowBackend.actions == [.disable])
        #expect(tomorrow.status == .available(.disabled))
    }

    @Test("Turn Off Until Tomorrow remains a distinct temporary action")
    func temporaryDisable() async {
        let backend = FakeOptimizedChargingBackend(
            reads: [
                .success(.enabled),
                .success(.disabledUntilTomorrow),
            ],
            writes: [.success(())])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.disableUntilTomorrow()

        #expect(backend.actions == [.disableUntilTomorrow])
        #expect(controller.status == .available(.disabledUntilTomorrow))
    }

    @Test("Stable choices and invalid temporary actions never write")
    func noOpWrites() async {
        let backend = FakeOptimizedChargingBackend(reads: [
            .success(.enabled)
        ])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setEnabled(true)

        #expect(backend.actions.isEmpty)
        #expect(controller.status == .available(.enabled))
    }

    @Test("A failed write restores authoritative state and reports failure")
    func failedWriteReconciles() async {
        let backend = FakeOptimizedChargingBackend(
            reads: [.success(.enabled), .success(.enabled)],
            writes: [.failure(OptimizedTestFailure.expected)])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setEnabled(false)

        #expect(controller.status == .available(.enabled))
        #expect(controller.lastErrorMessage ==
            "Optimized Battery Charging could not be changed.")
    }

    @Test("A thrown write that landed is accepted after readback")
    func thrownWriteLanded() async {
        let backend = FakeOptimizedChargingBackend(
            reads: [.success(.enabled), .success(.disabled)],
            writes: [.failure(OptimizedTestFailure.expected)])
        let controller = Self.controller(backend)
        await controller.refresh()

        await controller.setEnabled(false)

        #expect(controller.status == .available(.disabled))
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("Cancellation before dispatch performs no write or reconciliation")
    func cancellationBeforeWrite() async {
        let transactions = SmartChargingTransactionCoordinator()
        let backend = FakeOptimizedChargingBackend(reads: [
            .success(.enabled)
        ])
        let controller = Self.controller(backend, transactions: transactions)
        await controller.refresh()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.setEnabled(false)
        }
        await task.value

        #expect(backend.actions.isEmpty)
        #expect(transactions.reconciliationGeneration == 0)
        #expect(!transactions.isMutating)
    }

    @Test("Cancellation after dispatch reconciles authoritative state")
    func cancellationAfterWrite() async {
        let transactions = SmartChargingTransactionCoordinator()
        let backend = FakeOptimizedChargingBackend(reads: [
            .success(.enabled),
            .success(.disabled),
        ])
        let writer = GatedOptimizedWriter()
        let controller = OptimizedChargingController(
            readConfiguration: backend.read,
            writeAction: writer.write,
            transactionCoordinator: transactions)
        await controller.refresh()

        let task = Task { await controller.setEnabled(false) }
        await writer.waitForWrite()
        task.cancel()
        writer.release(with: .success(()))
        await task.value

        #expect(writer.actions == [.disable])
        #expect(controller.status == .available(.disabled))
        #expect(controller.lastErrorMessage == nil)
        #expect(transactions.reconciliationGeneration == 1)
        #expect(!transactions.isMutating)
    }

    @Test("A read predating a mutation cannot publish afterward")
    func staleRefreshIsDiscarded() async {
        let transactions = SmartChargingTransactionCoordinator()
        let reader = GatedOptimizedReader(
            results: [
                .success(.enabled),
                .success(.enabled),
                .success(.disabled),
            ],
            gatedCall: 2)
        let backend = FakeOptimizedChargingBackend(
            reads: [],
            writes: [.success(())])
        let controller = OptimizedChargingController(
            readConfiguration: reader.read,
            writeAction: backend.write,
            transactionCoordinator: transactions)
        await controller.refresh()

        let staleRefresh = Task { await controller.refresh() }
        await reader.waitForGatedRead()
        await controller.setEnabled(false)
        reader.release()
        await staleRefresh.value

        #expect(controller.status == .available(.disabled))
    }

    @Test("A Charge Limit write reconciles its OBC side effect before release")
    func crossFeatureReconciliation() async {
        let transactions = SmartChargingTransactionCoordinator()
        let backend = CrossFeatureChargingBackend()
        let chargeLimit = ChargeLimitController(
            readConfiguration: backend.readLimit,
            writeLimit: backend.writeLimit,
            transactionCoordinator: transactions)
        let optimized = OptimizedChargingController(
            readConfiguration: backend.readOptimized,
            writeAction: { _ in },
            transactionCoordinator: transactions)
        await chargeLimit.refresh()
        await optimized.refresh()
        #expect(optimized.status == .available(.disabledUntilTomorrow))

        await chargeLimit.setLimit(90)

        #expect(chargeLimit.displayedLimit == 90)
        #expect(optimized.status == .available(.enabled))
        #expect(transactions.reconciliationGeneration == 1)
        #expect(!transactions.isMutating)
    }

    @Test("Battery Settings action uses the injected opener")
    func openBatterySettings() {
        var openCount = 0
        let controller = OptimizedChargingController(
            readConfiguration: { nil },
            writeAction: { _ in },
            openBatterySettingsAction: { openCount += 1 })

        controller.openBatterySettings()

        #expect(openCount == 1)
    }

    private static func controller(
        _ backend: FakeOptimizedChargingBackend,
        transactions: SmartChargingTransactionCoordinator? = nil
    ) -> OptimizedChargingController {
        let transactions = transactions
            ?? SmartChargingTransactionCoordinator()
        return OptimizedChargingController(
            readConfiguration: backend.read,
            writeAction: backend.write,
            transactionCoordinator: transactions)
    }
}

private enum OptimizedTestFailure: Error {
    case expected
    case noQueuedRead
    case noQueuedWrite
}
