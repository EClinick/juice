import Foundation
import Testing
@testable import Juice
@testable import JuiceXPCShared

/// Records what the controller asked of `pmset` and of the helper so the state
/// machine can be exercised without root or a real XPC connection.
@MainActor
private final class FakeEnergyModeBackend {
    private var readStates: [PowerModeState?]
    private var writeResults: [Result<PowerModeState, Error>]
    private(set) var writes: [(mode: PowerMode, scope: PowerModeScope)] = []
    private(set) var readCount = 0

    init(
        readStates: [PowerModeState?],
        writeResults: [Result<PowerModeState, Error>] = []
    ) {
        self.readStates = readStates
        self.writeResults = writeResults
    }

    /// Returns each queued read in order, repeating the last one afterwards so a
    /// test only has to describe the states it cares about.
    nonisolated var read: @Sendable () async -> PowerModeState? {
        { await self.nextRead() }
    }

    nonisolated var write: @Sendable (PowerMode, PowerModeScope) async throws -> PowerModeState {
        { mode, scope in try await self.performWrite(mode, scope) }
    }

    private func nextRead() -> PowerModeState? {
        readCount += 1
        guard !readStates.isEmpty else { return nil }
        return readStates.count == 1 ? readStates[0] : readStates.removeFirst()
    }

    private func performWrite(
        _ mode: PowerMode,
        _ scope: PowerModeScope
    ) throws -> PowerModeState {
        writes.append((mode, scope))
        guard !writeResults.isEmpty else {
            throw HelperError.error(.internalError, message: "no queued result")
        }
        return try writeResults.removeFirst().get()
    }
}

/// A `readState` seam that parks its FIRST read until the test releases it, and
/// lets the test await that read's arrival, so a refresh can be raced against a
/// write by handshake rather than by scheduler luck. Later reads - the recovery
/// refresh a failed write kicks off - pass straight through.
private final class GatedReader: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PowerModeState?]
    private var started = 0
    private var released = false
    private var reader: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    /// One state per read, in order; the last is repeated afterwards.
    init(_ results: [PowerModeState?]) {
        self.results = results
    }

    var read: @Sendable () async -> PowerModeState? {
        { await self.next() }
    }

    /// Resumes once a read has reached the gate.
    func waitForFirstRead() async {
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

    func release() {
        lock.lock()
        released = true
        let waiting = reader
        reader = nil
        lock.unlock()
        waiting?.resume()
    }

    private func next() async -> PowerModeState? {
        let (isFirst, result) = beginRead()
        guard isFirst else { return result }
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
        return result
    }

    /// Claims this read's result and wakes ``waitForFirstRead()``. Synchronous
    /// so the lock is never held across a suspension point.
    private func beginRead() -> (isFirst: Bool, result: PowerModeState?) {
        lock.lock()
        started += 1
        let isFirst = started == 1
        let result = results.count > 1 ? results.removeFirst() : results.first ?? nil
        let arrived = arrival
        arrival = nil
        lock.unlock()
        arrived?.resume()
        return (isFirst, result)
    }
}

@MainActor
@Suite("Energy mode controller")
struct EnergyModeControllerTests {
    private static func modern(
        battery: PowerMode = .automatic,
        ac: PowerMode = .automatic
    ) -> PowerModeState {
        PowerModeState(battery: battery, ac: ac, keyLayout: .unified)
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "EnergyModeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// `currentOnAC` returns nil by default so the caller's `onAC` decides the
    /// scope: tests must not depend on how the test machine is plugged in.
    private static func makeController(
        backend: FakeEnergyModeBackend,
        defaults: UserDefaults? = nil,
        currentOnAC: @escaping @Sendable () -> Bool? = { nil }
    ) -> EnergyModeController {
        EnergyModeController(
            defaults: defaults ?? isolatedDefaults(),
            readState: backend.read,
            writeState: backend.write,
            currentOnAC: currentOnAC)
    }

    @Test("Refresh publishes the parsed state")
    func refreshPublishesState() async {
        let backend = FakeEnergyModeBackend(readStates: [Self.modern(battery: .lowPower)])
        let controller = Self.makeController(backend: backend)

        await controller.refresh()

        #expect(controller.state == Self.modern(battery: .lowPower))
        #expect(controller.showsHighPower)
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("An unreadable machine publishes no state and no error text")
    func refreshFailureIsQuiet() async {
        let backend = FakeEnergyModeBackend(readStates: [nil])
        let controller = Self.makeController(backend: backend)

        await controller.refresh()

        #expect(controller.state == nil)
        #expect(controller.lastErrorMessage == nil)
        #expect(!controller.showsHighPower)
    }

    @Test("A successful write publishes the helper's read-back state")
    func writePublishesReadBack() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [.success(Self.modern(battery: .lowPower))])
        let controller = Self.makeController(backend: backend)
        await controller.refresh()

        await controller.set(.lowPower, onAC: false)

        #expect(controller.state == Self.modern(battery: .lowPower))
        #expect(!controller.isWriting)
        #expect(controller.pendingMode == nil)
        #expect(controller.lastErrorMessage == nil)
        // The read-back is authoritative: no extra pmset read is spawned.
        #expect(backend.readCount == 1)
    }

    @Test("Scope follows the power source currently in use", arguments: [
        (false, PowerModeScope.battery), (true, PowerModeScope.ac)
    ])
    func scopeFollowsPowerSource(onAC: Bool, expected: PowerModeScope) async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [.success(Self.modern(battery: .lowPower, ac: .lowPower))])
        let controller = Self.makeController(backend: backend)

        await controller.set(.lowPower, onAC: onAC)

        #expect(backend.writes.map(\.scope) == [expected])
        #expect(backend.writes.map(\.mode) == [PowerMode.lowPower])
    }

    @Test("An outdated helper is reported instead of an error message")
    func outdatedHelper() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [.failure(HelperClientError.helperOutdated)])
        let controller = Self.makeController(backend: backend)
        await controller.refresh()

        await controller.set(.lowPower, onAC: false)

        #expect(controller.needsHelperUpdate)
        #expect(controller.lastErrorMessage == nil)
        #expect(controller.state == Self.modern())
    }

    @Test("Observed High Power heals a wrongly poisoned unsupported cache")
    func observedHighPowerHealsTheCache() async {
        let defaults = Self.isolatedDefaults()
        // An external write racing the helper's read-back can misclassify a
        // supported machine as refusing High Power; a later read that shows
        // High Power actually set is proof of support and must clear it.
        defaults.set(true, forKey: EnergyModeController.highPowerUnsupportedKey)
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern(battery: .highPower)])
        let controller = Self.makeController(backend: backend, defaults: defaults)
        #expect(!controller.showsHighPower)

        await controller.refresh()

        #expect(controller.showsHighPower)
        #expect(defaults.object(forKey: EnergyModeController.highPowerUnsupportedKey) == nil)
    }

    @Test("A high-power write the hardware refuses hides the option for good")
    func refusedHighPowerIsCached() async {
        let defaults = Self.isolatedDefaults()
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [
                .failure(HelperError.error(.unsupportedPowerMode, message: "nope"))
            ])
        let controller = Self.makeController(backend: backend, defaults: defaults)
        await controller.refresh()

        await controller.set(.highPower, onAC: false)

        #expect(!controller.showsHighPower)
        #expect(controller.lastErrorMessage == "This Mac does not support High Power.")
        // Re-synced after the failure, and remembered across relaunches.
        #expect(backend.readCount == 2)
        #expect(defaults.bool(forKey: EnergyModeController.highPowerUnsupportedKey))

        let reloaded = EnergyModeController(
            defaults: defaults,
            readState: backend.read,
            writeState: backend.write,
            currentOnAC: { nil })
        await reloaded.refresh()
        #expect(!reloaded.showsHighPower)
    }

    @Test("A transient high-power failure is reported but never hides the option")
    func transientHighPowerFailureKeepsOption() async {
        let defaults = Self.isolatedDefaults()
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [
                .failure(HelperError.error(.powerSettingFailed, message: "pmset exited 1"))
            ])
        let controller = Self.makeController(backend: backend, defaults: defaults)
        await controller.refresh()

        await controller.set(.highPower, onAC: false)

        // pmset failing outright says nothing about the hardware, so High Power
        // stays offered and nothing is remembered.
        #expect(controller.showsHighPower)
        #expect(controller.lastErrorMessage == "macOS did not apply the new Energy Mode.")
        #expect(!defaults.bool(forKey: EnergyModeController.highPowerUnsupportedKey))
    }

    @Test("The scope follows the live power source, not the caller's stale reading")
    func scopeFollowsLiveSource() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [.success(Self.modern(ac: .lowPower))])
        let controller = Self.makeController(backend: backend, currentOnAC: { true })

        // The view's reading is refreshed on a timer, so it can still say
        // "on battery" moments after the machine was plugged in.
        await controller.set(.lowPower, onAC: false)

        #expect(backend.writes.map(\.scope) == [PowerModeScope.ac])
    }

    @Test("A refresh that started before a write cannot roll the write back")
    func staleRefreshIsDiscarded() async {
        let stale = Self.modern(battery: .automatic)
        let written = Self.modern(battery: .highPower)
        let reader = GatedReader([stale])
        let controller = EnergyModeController(
            defaults: Self.isolatedDefaults(),
            readState: reader.read,
            writeState: { _, _ in written },
            currentOnAC: { nil })

        let refreshing = Task { await controller.refresh() }
        // Ordered by the reader's own arrival, not by yielding and hoping.
        await reader.waitForFirstRead()
        await controller.set(.highPower, onAC: false)
        #expect(controller.state == written)

        reader.release()
        await refreshing.value

        #expect(controller.state == written)
    }

    @Test("A refresh that started before a FAILED write cannot roll its recovery back")
    func staleRefreshIsDiscardedAfterFailure() async {
        let stale = Self.modern(battery: .automatic)
        // What the machine actually reports once the failed write is investigated.
        let recovered = Self.modern(battery: .highPower)
        let reader = GatedReader([stale, recovered])
        let controller = EnergyModeController(
            defaults: Self.isolatedDefaults(),
            readState: reader.read,
            writeState: { _, _ in
                throw HelperError.error(.powerSettingFailed, message: "pmset exited 1")
            },
            currentOnAC: { nil })

        let refreshing = Task { await controller.refresh() }
        await reader.waitForFirstRead()
        // The failure's own recovery read is the authoritative state.
        await controller.set(.lowPower, onAC: false)
        #expect(controller.state == recovered)
        #expect(controller.lastErrorMessage == "macOS did not apply the new Energy Mode.")

        reader.release()
        await refreshing.value

        // The older refresh must neither restore the stale state nor clear the
        // message explaining why the machine is not showing what was asked for.
        #expect(controller.state == recovered)
        #expect(controller.lastErrorMessage == "macOS did not apply the new Energy Mode.")
    }

    @Test("A tap that matches only the stale caller's source still writes")
    func noOpIsDecidedAgainstTheLiveSource() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern(battery: .lowPower, ac: .automatic)],
            writeResults: [.success(Self.modern(battery: .lowPower, ac: .lowPower))])
        let controller = Self.makeController(backend: backend, currentOnAC: { true })
        await controller.refresh()

        // The view still thinks the machine is on battery, where Low Power is
        // already selected - but the live source is AC, which is Automatic.
        await controller.set(.lowPower, onAC: false)

        #expect(backend.writes.map(\.scope) == [PowerModeScope.ac])
        #expect(controller.state == Self.modern(battery: .lowPower, ac: .lowPower))
    }

    @Test("A tap on the live source's current mode writes nothing")
    func matchingModeSkipsTheWrite() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern(battery: .lowPower, ac: .automatic)])
        let controller = Self.makeController(backend: backend, currentOnAC: { true })
        await controller.refresh()

        await controller.set(.automatic, onAC: false)

        #expect(backend.writes.isEmpty)
        #expect(!controller.isWriting)
        #expect(controller.state == Self.modern(battery: .lowPower, ac: .automatic))
    }

    @Test("An upgraded helper clears the restart notice")
    func helperUpdateClearsNotice() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [.failure(HelperClientError.helperOutdated)])
        let controller = Self.makeController(backend: backend)

        await controller.set(.lowPower, onAC: false)
        #expect(controller.needsHelperUpdate)

        controller.helperMayHaveUpdated()

        #expect(!controller.needsHelperUpdate)
    }

    @Test("A refused low-power write surfaces a short message and re-syncs")
    func otherFailuresSurfaceMessage() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern(), Self.modern(battery: .highPower)],
            writeResults: [
                .failure(HelperError.error(.powerSettingFailed, message: "pmset exited 1"))
            ])
        let controller = Self.makeController(backend: backend)
        await controller.refresh()

        await controller.set(.lowPower, onAC: false)

        #expect(controller.lastErrorMessage == "macOS did not apply the new Energy Mode.")
        #expect(controller.state == Self.modern(battery: .highPower))
        #expect(backend.readCount == 2)
        #expect(!controller.needsHelperUpdate)
    }

    @Test("High Power is never offered on a lowpowermode-only machine")
    func lowPowerOnlyMachineHidesHighPower() async {
        let backend = FakeEnergyModeBackend(readStates: [
            PowerModeState(battery: .lowPower, ac: .automatic, keyLayout: .lowPowerOnly)
        ])
        let controller = Self.makeController(backend: backend)

        await controller.refresh()

        #expect(!controller.showsHighPower)
    }

    @Test("High Power is offered on a dual-boolean machine")
    func dualBooleanMachineShowsHighPower() async {
        // Those Macs publish no `powermode` key, but they do have High Power:
        // reading their `lowpowermode` as the legacy layout used to hide it.
        let backend = FakeEnergyModeBackend(readStates: [
            PowerModeState(battery: .lowPower, ac: .highPower, keyLayout: .dualBoolean)
        ])
        let controller = Self.makeController(backend: backend)

        await controller.refresh()

        #expect(controller.showsHighPower)
    }

    @Test("A later successful write clears a stale error message")
    func successClearsError() async {
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [
                .failure(HelperError.error(.internalError, message: "boom")),
                .success(Self.modern(battery: .lowPower))
            ])
        let controller = Self.makeController(backend: backend)

        await controller.set(.lowPower, onAC: false)
        #expect(controller.lastErrorMessage == "Energy Mode could not be changed.")

        await controller.set(.lowPower, onAC: false)
        #expect(controller.lastErrorMessage == nil)
        #expect(controller.state == Self.modern(battery: .lowPower))
    }
}
