import Foundation
import Testing
@testable import Juice
@testable import JuiceCore

@Suite("Energy source selection")
struct EnergySourceSelectorTests {
    @Test("A successful empty helper query is live, not unavailable")
    func successfulEmptyLiveQuery() async {
        let selector = EnergySourceSelector(
            liveSource: StubEnergySource(result: .success([])),
            store: { nil })

        let result = await selector.topApps(range: .today)

        #expect(result.origin == .live)
        #expect(result.apps.isEmpty)
        #expect(result.errorDescription == nil)
    }

    @Test("A successful helper query returns live app energy")
    func successfulLiveQuery() async {
        let app = AppEnergy(
            bundleId: "test.app", displayName: "Test", energyWh: 1.25, cpuHours: 0.5)
        let selector = EnergySourceSelector(
            liveSource: StubEnergySource(result: .success([app])),
            store: { nil })

        let result = await selector.topApps(range: .today)

        #expect(result.origin == .live)
        #expect(result.apps.map(\.bundleId) == ["test.app"])
    }

    @Test("A thrown helper query returns no fabricated data")
    func failedLiveQuery() async {
        let selector = EnergySourceSelector(
            liveSource: StubEnergySource(result: .failure(TestFailure.unavailable)),
            store: { nil })

        let result = await selector.topApps(range: .today)

        #expect(result.origin == .unavailable)
        #expect(result.apps.isEmpty)
        #expect(result.errorDescription != nil)
    }

    @Test("Stored historical rollups take precedence over the live helper")
    func storedHistoryWins() async throws {
        let store = try JuiceStore(path: temporaryDatabasePath())
        try store.upsertRollups([
            DailyEnergyRollup(day: todayKey(), appKey: "stored.app", wh: 3.5, cpuHours: 1)
        ])
        let live = TrackingEnergySource(result: .failure(TestFailure.unavailable))
        let selector = EnergySourceSelector(
            liveSource: live,
            store: { store })

        let result = await selector.topApps(range: .week)

        #expect(result.origin == .store)
        #expect(result.apps.map(\.bundleId) == ["stored.app"])
        #expect(live.callCount == 0)
    }

    @Test("An empty historical store falls through to live data")
    func emptyStoreFallsThrough() async throws {
        let store = try JuiceStore(path: temporaryDatabasePath())
        let app = AppEnergy(
            bundleId: "live.app", displayName: "Live", energyWh: 2, cpuHours: 0.25)
        let selector = EnergySourceSelector(
            liveSource: StubEnergySource(result: .success([app])),
            store: { store })

        let result = await selector.topApps(range: .week)

        #expect(result.origin == .live)
        #expect(result.apps.map(\.bundleId) == ["live.app"])
    }

    @Test("A historical store read error falls through to live data")
    func storeErrorFallsThrough() async throws {
        let store = try JuiceStore(path: temporaryDatabasePath())
        let selector = EnergySourceSelector(
            liveSource: StubEnergySource(result: .success([])),
            storedApps: { _, _ in throw TestFailure.unavailable },
            store: { store })

        let result = await selector.topApps(range: .week)

        #expect(result.origin == .live)
        #expect(result.apps.isEmpty)
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-selector-\(UUID().uuidString).sqlite")
            .path
    }

    private func todayKey() -> String {
        RollupBuilder.dayFormatter().string(from: Date())
    }
}

private enum TestFailure: Error {
    case unavailable
}

private struct StubEnergySource: EnergySource {
    let result: Result<[AppEnergy], Error>

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        try result.get()
    }

    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample] {
        []
    }
}

private final class TrackingEnergySource: EnergySource, @unchecked Sendable {
    let result: Result<[AppEnergy], Error>
    private let lock = NSLock()
    private var _callCount = 0

    init(result: Result<[AppEnergy], Error>) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        lock.withLock { _callCount += 1 }
        return try result.get()
    }

    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample] {
        []
    }
}
