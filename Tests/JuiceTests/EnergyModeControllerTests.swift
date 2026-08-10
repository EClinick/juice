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

    private static func makeController(
        backend: FakeEnergyModeBackend,
        defaults: UserDefaults? = nil
    ) -> EnergyModeController {
        EnergyModeController(
            defaults: defaults ?? isolatedDefaults(),
            readState: backend.read,
            writeState: backend.write)
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

    @Test("A refused high-power write hides the option for good", arguments: [
        HelperError.Code.powerSettingFailed, .unsupportedPowerMode
    ])
    func refusedHighPowerIsCached(code: HelperError.Code) async {
        let defaults = Self.isolatedDefaults()
        let backend = FakeEnergyModeBackend(
            readStates: [Self.modern()],
            writeResults: [.failure(HelperError.error(code, message: "nope"))])
        let controller = Self.makeController(backend: backend, defaults: defaults)
        await controller.refresh()

        await controller.set(.highPower, onAC: false)

        #expect(!controller.showsHighPower)
        #expect(controller.lastErrorMessage != nil)
        // Re-synced after the failure, and remembered across relaunches.
        #expect(backend.readCount == 2)
        #expect(defaults.bool(forKey: EnergyModeController.highPowerUnsupportedKey))

        let reloaded = EnergyModeController(
            defaults: defaults,
            readState: backend.read,
            writeState: backend.write)
        await reloaded.refresh()
        #expect(!reloaded.showsHighPower)
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
