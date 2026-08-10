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

/// Holds a read inside the controller until the test releases it, so an
/// in-flight refresh can be raced against a write deterministically.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

@MainActor
@Suite("Energy mode controller")
struct EnergyModeControllerTests {
    private static func modern(
        battery: PowerMode = .automatic,
        ac: PowerMode = .automatic
    ) -> PowerModeState {
        PowerModeState(battery: battery, ac: ac, usesLegacyLowPowerKey: false)
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
        let gate = ReadGate()
        let stale = Self.modern(battery: .automatic)
        let written = Self.modern(battery: .highPower)
        let controller = EnergyModeController(
            defaults: Self.isolatedDefaults(),
            readState: {
                await gate.wait()
                return stale
            },
            writeState: { _, _ in written },
            currentOnAC: { nil })

        let refreshing = Task { await controller.refresh() }
        // Let the refresh reach the gate, so it is genuinely in flight.
        await Task.yield()
        await controller.set(.highPower, onAC: false)
        #expect(controller.state == written)

        gate.release()
        await refreshing.value

        #expect(controller.state == written)
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

    @Test("High Power is never offered on a legacy lowpowermode machine")
    func legacyMachineHidesHighPower() async {
        let backend = FakeEnergyModeBackend(readStates: [
            PowerModeState(battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: true)
        ])
        let controller = Self.makeController(backend: backend)

        await controller.refresh()

        #expect(!controller.showsHighPower)
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
