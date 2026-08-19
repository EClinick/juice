import Foundation
import Testing
@testable import Juice

@MainActor
private final class FakeChargeToFullBackend {
    private var reads: [Result<SystemChargeHold?, Error>]
    private var writes: [Result<Void, Error>]
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(
        reads: [Result<SystemChargeHold?, Error>],
        writes: [Result<Void, Error>] = []
    ) {
        self.reads = reads
        self.writes = writes
    }

    nonisolated var read: @Sendable () async throws -> SystemChargeHold? {
        { try await self.nextRead() }
    }

    nonisolated var write: @Sendable () async throws -> Void {
        { try await self.nextWrite() }
    }

    private func nextRead() throws -> SystemChargeHold? {
        readCount += 1
        guard !reads.isEmpty else { return nil }
        let result = reads.count == 1 ? reads[0] : reads.removeFirst()
        return try result.get()
    }

    private func nextWrite() throws {
        writeCount += 1
        guard !writes.isEmpty else {
            throw TestFailure.noQueuedWrite
        }
        try writes.removeFirst().get()
    }

    private enum TestFailure: Error {
        case noQueuedWrite
    }
}

/// Parks one selected read so refresh ordering is controlled by a handshake,
/// not scheduler timing.
private final class GatedChargeStatusReader: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<SystemChargeHold?, Error>]
    private let gatedCall: Int
    private var started = 0
    private var released = false
    private var reader: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(
        _ results: [Result<SystemChargeHold?, Error>],
        gatedCall: Int
    ) {
        self.results = results
        self.gatedCall = gatedCall
    }

    var read: @Sendable () async throws -> SystemChargeHold? {
        { try await self.next() }
    }

    func waitForGatedRead() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard started < gatedCall else {
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

    private func next() async throws -> SystemChargeHold? {
        let (shouldWait, result) = beginRead()
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

    private func beginRead() -> (
        shouldWait: Bool,
        result: Result<SystemChargeHold?, Error>
    ) {
        lock.lock()
        started += 1
        let shouldWait = started == gatedCall
        let result = results.count > 1 ? results.removeFirst() : results[0]
        let arrived = shouldWait ? arrival : nil
        if shouldWait { arrival = nil }
        lock.unlock()
        arrived?.resume()
        return (shouldWait, result)
    }
}

/// Records entry into a write and parks it until the test supplies the result.
private final class GatedChargeWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var result: Result<Void, Error>?
    private var writer: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    var write: @Sendable () async throws -> Void {
        { try await self.perform() }
    }

    var callCount: Int {
        lock.withLock { started }
    }

    func waitForWrite() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard started == 0 else {
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

    private func perform() async throws {
        let arrived = beginWrite()
        arrived?.resume()

        await withCheckedContinuation { continuation in
            let alreadyReleased = lock.withLock {
                guard self.result == nil else { return true }
                writer = continuation
                return false
            }
            if alreadyReleased {
                continuation.resume()
            }
        }

        let outcome = lock.withLock { self.result }
        try outcome!.get()
    }

    private func beginWrite() -> CheckedContinuation<Void, Never>? {
        lock.withLock {
            started += 1
            defer { arrival = nil }
            return arrival
        }
    }
}

@MainActor
@Suite("Charge to Full controller")
struct ChargeToFullControllerTests {
    private nonisolated static func reading(
        percent: Int = 80,
        onAC: Bool = true,
        isCharging: Bool = false,
        hasBattery: Bool = true
    ) -> BatteryReading {
        BatteryReading(
            percent: percent,
            watts: isCharging ? -12 : 0,
            isCharging: isCharging,
            onAC: onAC,
            timeRemainingMinutes: nil,
            cycleCount: 24,
            healthPercent: 100,
            hasBattery: hasBattery)
    }

    private static func controller(
        _ backend: FakeChargeToFullBackend
    ) -> ChargeToFullController {
        ChargeToFullController(
            readStatus: backend.read,
            requestFullCharge: backend.write)
    }

    @Test("An authoritative optimized hold shows the system command")
    func optimizedHold() async {
        let backend = FakeChargeToFullBackend(reads: [
            .success(SystemChargeHold(kind: .optimized, chargeLimit: 100))
        ])
        let controller = Self.controller(backend)

        await controller.refresh(reading: Self.reading(percent: 79))

        #expect(controller.state == .ready(.optimized(currentPercent: 79)))
        #expect(controller.state?.headline == "Charging On Hold")
    }

    @Test("A configured limit uses its actual percentage")
    func configuredLimit() async {
        let backend = FakeChargeToFullBackend(reads: [
            .success(SystemChargeHold(kind: .limit, chargeLimit: 85))
        ])
        let controller = Self.controller(backend)

        await controller.refresh(reading: Self.reading(percent: 85))

        #expect(controller.state == .ready(.limit(percent: 85)))
        #expect(controller.state?.headline == "Charged to 85% Limit")
    }

    @Test("Generic not-charging states never fabricate the action")
    func genericPauseStaysHidden() async {
        let backend = FakeChargeToFullBackend(reads: [.success(nil)])
        let controller = Self.controller(backend)

        await controller.refresh(reading: Self.reading())

        #expect(controller.state == nil)
        #expect(backend.readCount == 1)
    }

    @Test("An invalid configured percentage fails closed")
    func invalidConfiguredLimit() async {
        let backend = FakeChargeToFullBackend(reads: [
            .success(SystemChargeHold(kind: .limit, chargeLimit: 100))
        ])
        let controller = Self.controller(backend)

        await controller.refresh(reading: Self.reading())

        #expect(controller.state == nil)
    }

    @Test("Ineligible battery contexts skip the private state read", arguments: [
        Self.reading(onAC: false),
        Self.reading(isCharging: true),
        Self.reading(percent: 100),
        Self.reading(hasBattery: false)
    ])
    func ineligibleContext(reading: BatteryReading) async {
        let backend = FakeChargeToFullBackend(reads: [
            .success(SystemChargeHold(kind: .optimized, chargeLimit: 100))
        ])
        let controller = Self.controller(backend)

        await controller.refresh(reading: reading)

        #expect(controller.state == nil)
        #expect(backend.readCount == 0)
    }

    @Test("Accepted requests invoke the atomic macOS override once", arguments: [
        SystemChargeHold(kind: .optimized, chargeLimit: 100),
        SystemChargeHold(kind: .limit, chargeLimit: 80)
    ])
    func acceptedRequest(hold: SystemChargeHold) async {
        let backend = FakeChargeToFullBackend(
            reads: [.success(hold)],
            writes: [.success(())])
        let controller = Self.controller(backend)
        await controller.refresh(reading: Self.reading())

        let accepted = await controller.chargeToFull()

        #expect(accepted)
        #expect(backend.writeCount == 1)
        #expect(controller.state == .accepted(controller.state!.reason))
        #expect(!controller.isRequesting)
    }

    @Test("A failed request stays visible and can be retried")
    func failureCanRetry() async {
        enum Failure: Error { case refused }
        let backend = FakeChargeToFullBackend(
            reads: [
                .success(SystemChargeHold(kind: .optimized, chargeLimit: 100))
            ],
            writes: [.failure(Failure.refused), .success(())])
        let controller = Self.controller(backend)
        await controller.refresh(reading: Self.reading())

        #expect(!(await controller.chargeToFull()))
        #expect(controller.state == .failed(.optimized(currentPercent: 80)))

        #expect(await controller.chargeToFull())
        #expect(backend.writeCount == 2)
        #expect(controller.state == .accepted(.optimized(currentPercent: 80)))
    }

    @Test("Detection failures are quiet and fail closed")
    func detectionFailure() async {
        enum Failure: Error { case unavailable }
        let backend = FakeChargeToFullBackend(reads: [.failure(Failure.unavailable)])
        let controller = Self.controller(backend)

        await controller.refresh(reading: Self.reading())

        #expect(controller.state == nil)
    }

    @Test("An older slow refresh cannot replace a newer result")
    func olderRefreshIsDiscarded() async {
        let hold = SystemChargeHold(kind: .optimized, chargeLimit: 100)
        let reader = GatedChargeStatusReader(
            [.success(nil), .success(hold)],
            gatedCall: 1)
        let controller = ChargeToFullController(
            readStatus: reader.read,
            requestFullCharge: {})

        let older = Task { await controller.refresh(reading: Self.reading()) }
        await reader.waitForGatedRead()
        let newer = Task { await controller.refresh(reading: Self.reading(percent: 79)) }
        await newer.value
        #expect(controller.state == .ready(.optimized(currentPercent: 79)))

        reader.release()
        await older.value

        #expect(controller.state == .ready(.optimized(currentPercent: 79)))
    }

    @Test("A read that predates a write cannot roll its accepted state back")
    func refreshPredatingWriteIsDiscarded() async {
        let hold = SystemChargeHold(kind: .optimized, chargeLimit: 100)
        let reader = GatedChargeStatusReader(
            [.success(hold), .success(hold)],
            gatedCall: 2)
        let controller = ChargeToFullController(
            readStatus: reader.read,
            requestFullCharge: {})
        await controller.refresh(reading: Self.reading())

        let staleRefresh = Task {
            await controller.refresh(reading: Self.reading(percent: 79))
        }
        await reader.waitForGatedRead()
        #expect(await controller.chargeToFull())

        reader.release()
        await staleRefresh.value

        #expect(controller.state == .accepted(.optimized(currentPercent: 80)))
    }

    @Test("Double taps dispatch only one macOS request")
    func doubleTapIsCoalesced() async {
        let hold = SystemChargeHold(kind: .optimized, chargeLimit: 100)
        let write = GatedChargeWrite()
        let controller = ChargeToFullController(
            readStatus: { hold },
            requestFullCharge: write.write)
        await controller.refresh(reading: Self.reading())

        let first = Task { await controller.chargeToFull() }
        await write.waitForWrite()
        #expect(!(await controller.chargeToFull()))

        write.release(with: .success(()))
        #expect(await first.value)
        #expect(write.callCount == 1)
    }

    @Test("Cancellation before dispatch performs no write")
    func cancellationBeforeDispatch() async {
        let backend = FakeChargeToFullBackend(
            reads: [
                .success(SystemChargeHold(kind: .optimized, chargeLimit: 100))
            ],
            writes: [.success(())])
        let controller = Self.controller(backend)
        await controller.refresh(reading: Self.reading())

        let request = Task { await controller.chargeToFull() }
        request.cancel()

        #expect(!(await request.value))
        #expect(backend.writeCount == 0)
        #expect(controller.state == .ready(.optimized(currentPercent: 80)))
    }

    @Test("Cancellation after dispatch reconciles authoritative state")
    func cancellationAfterDispatch() async {
        let hold = SystemChargeHold(kind: .optimized, chargeLimit: 100)
        let backend = FakeChargeToFullBackend(reads: [
            .success(hold),
            .success(nil)
        ])
        let write = GatedChargeWrite()
        let controller = ChargeToFullController(
            readStatus: backend.read,
            requestFullCharge: write.write)
        await controller.refresh(reading: Self.reading())

        let request = Task { await controller.chargeToFull() }
        await write.waitForWrite()
        request.cancel()
        write.release(with: .failure(CancellationError()))

        #expect(!(await request.value))
        #expect(write.callCount == 1)
        #expect(backend.readCount == 2)
        #expect(controller.state == nil)
    }

    @Test("Confirmed transition remains stable until battery current catches up")
    func acceptedTransitionDoesNotFlashAway() async {
        let backend = FakeChargeToFullBackend(
            reads: [
                .success(SystemChargeHold(kind: .optimized, chargeLimit: 100)),
                .success(SystemChargeHold(kind: .optimized, chargeLimit: 100)),
                .success(nil)
            ],
            writes: [.success(())])
        let controller = Self.controller(backend)
        await controller.refresh(reading: Self.reading())
        #expect(await controller.chargeToFull())

        await controller.refresh(reading: Self.reading())

        #expect(controller.state == .accepted(.optimized(currentPercent: 80)))

        await controller.refresh(reading: Self.reading())
        #expect(controller.state == .accepted(.optimized(currentPercent: 80)))

        await controller.refresh(reading: Self.reading(isCharging: true))
        #expect(controller.state == nil)
    }

    @Test("An unconfirmed transition does not claim charging forever")
    func acceptedTransitionExpires() async {
        var currentDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let backend = FakeChargeToFullBackend(
            reads: [
                .success(SystemChargeHold(kind: .optimized, chargeLimit: 100)),
                .success(nil)
            ],
            writes: [.success(())])
        let controller = ChargeToFullController(
            readStatus: backend.read,
            requestFullCharge: backend.write,
            now: { currentDate })
        await controller.refresh(reading: Self.reading())
        #expect(await controller.chargeToFull())

        currentDate.addTimeInterval(ChargeToFullController.confirmationGrace)
        await controller.refresh(reading: Self.reading())

        #expect(controller.state == nil)
    }
}
