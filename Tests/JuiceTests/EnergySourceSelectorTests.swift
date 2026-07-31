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

    @Test("All Time includes rollups older than the week window")
    func allTimeIncludesEntireStore() async throws {
        let store = try JuiceStore(path: temporaryDatabasePath())
        let oldDay = RollupBuilder.dayFormatter().string(
            from: Date().addingTimeInterval(-30 * 24 * 3600))
        try store.upsertRollups([
            DailyEnergyRollup(
                day: oldDay, appKey: "stored.app", wh: 4.0, cpuHours: 2.0),
            DailyEnergyRollup(
                day: todayKey(), appKey: "stored.app", wh: 1.5, cpuHours: 0.5),
        ])
        let live = TrackingEnergySource(result: .failure(TestFailure.unavailable))
        let selector = EnergySourceSelector(
            liveSource: live,
            store: { store })

        let week = await selector.topApps(range: .week)
        let allTime = await selector.topApps(range: .allTime)

        #expect(week.apps.first?.energyWh == 1.5)
        #expect(allTime.origin == .store)
        #expect(allTime.apps.first?.energyWh == 5.5)
        #expect(allTime.apps.first?.cpuHours == 2.5)
        #expect(allTime.coverageDayCount == 2)
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

    @Test("The selector limits only callers that request a cap")
    func optionalResultLimit() async {
        let apps = (0..<10).map { index in
            AppEnergy(
                bundleId: "app.\(index)", displayName: "App \(index)",
                energyWh: Double(10 - index), cpuHours: 0)
        }
        let selector = EnergySourceSelector(
            liveSource: StubEnergySource(result: .success(apps)),
            store: { nil })

        let full = await selector.topApps(range: .today)
        let popover = await selector.topApps(range: .today, limit: 8)

        #expect(full.apps.count == 10)
        #expect(popover.apps.count == 8)
        #expect(popover.apps.map(\.bundleId) == Array(full.apps.prefix(8).map(\.bundleId)))
    }

    @Test("All Time detail follows the source that served the row")
    func allTimeDetailUsesServedOrigin() {
        #expect(AppDetailPresenter.usesStoredHistory(range: .allTime, origin: .store))
        #expect(!AppDetailPresenter.usesStoredHistory(range: .allTime, origin: .live))
        #expect(AppDetailPresenter.usesStoredHistory(range: .week, origin: .store))
        #expect(!AppDetailPresenter.usesStoredHistory(range: .today, origin: .store))
    }

    @Test("Detail windows match stored history or live retention")
    func detailWindowPolicy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earliest = now.addingTimeInterval(-30 * 24 * 3600)

        let storedAllTime = AppDetailPresenter.windowStart(
            range: .allTime, usesStoredHistory: true,
            earliestStoredStart: earliest, now: now, calendar: calendar)
        let liveAllTime = AppDetailPresenter.windowStart(
            range: .allTime, usesStoredHistory: false,
            earliestStoredStart: nil, now: now, calendar: calendar)
        let liveWeek = AppDetailPresenter.windowStart(
            range: .week, usesStoredHistory: false,
            earliestStoredStart: nil, now: now, calendar: calendar)
        let serverToday = AppDetailPresenter.windowStart(
            range: .today, usesStoredHistory: true, isServerHistory: true,
            earliestStoredStart: earliest, now: now, calendar: calendar)
        let storedWeekDay = AppDetailPresenter.storedQueryStartDay(
            range: .week, now: now, calendar: calendar)
        let storedTodayDay = AppDetailPresenter.storedQueryStartDay(
            range: .today, now: now, calendar: calendar)
        let storedThreeDay = AppDetailPresenter.storedQueryStartDay(
            range: .threeDays, now: now, calendar: calendar)

        #expect(storedAllTime == earliest)
        #expect(liveAllTime == calendar.date(byAdding: .day, value: -3, to: now))
        #expect(liveWeek == calendar.date(byAdding: .day, value: -3, to: now))
        #expect(PowerlogEnergySource.rangeStart(
            for: .week, now: now, calendar: calendar) == liveWeek)
        #expect(PowerlogEnergySource.rangeStart(
            for: .allTime, now: now, calendar: calendar) == liveAllTime)
        #expect(serverToday == calendar.startOfDay(for: now))
        #expect(storedWeekDay == StoreEnergySource.sinceDay(
            for: .week, now: now, calendar: calendar))
        #expect(storedTodayDay == StoreEnergySource.sinceDay(
            for: .today, now: now, calendar: calendar))
        #expect(storedThreeDay == StoreEnergySource.sinceDay(
            for: .threeDays, now: now, calendar: calendar))
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

    @Test("Cancellation after a store read does not start a helper fallback")
    func cancellationStopsHistoricalFallback() async throws {
        let store = try JuiceStore(path: temporaryDatabasePath())
        let gate = SelectorStoreGate()
        let live = TrackingEnergySource(result: .success([]))
        let selector = EnergySourceSelector(
            liveSource: live,
            storedApps: { _, _ in await gate.load() },
            store: { store })

        let load = Task {
            await selector.topApps(range: .week)
        }
        await gate.waitUntilEntered()
        load.cancel()
        await gate.release(with: [])
        let result = await load.value

        #expect(result.origin == .loading)
        #expect(result.apps.isEmpty)
        #expect(live.callCount == 0)
    }

    @Test("A store CancellationError never becomes helper fallback demand")
    func storeCancellationErrorStopsFallback() async throws {
        let store = try JuiceStore(path: temporaryDatabasePath())
        let live = TrackingEnergySource(result: .success([]))
        let selector = EnergySourceSelector(
            liveSource: live,
            storedApps: { _, _ in throw CancellationError() },
            store: { store })

        let result = await selector.topApps(range: .week)

        #expect(result.origin == .loading)
        #expect(result.apps.isEmpty)
        #expect(live.callCount == 0)
    }

    @Test("A canceled live failure does not trigger helper recovery")
    func canceledLiveFailureSkipsRecovery() async {
        let live = SelectorLiveGate()
        let reporter = SelectorFailureReporter()
        let selector = EnergySourceSelector(
            liveSource: live,
            store: { nil },
            reportLiveFailure: { await reporter.record() })

        let load = Task {
            await selector.topApps(range: .today)
        }
        await live.waitUntilEntered()
        load.cancel()
        await live.fail(with: TestFailure.unavailable)
        let result = await load.value

        #expect(result.origin == .loading)
        #expect(result.apps.isEmpty)
        #expect(await reporter.callCount == 0)
    }

    @Test("Same-range restoration keeps cached historical rows")
    func sameRangeRestorationKeepsCache() {
        #expect(!HistoricalReloadPolicy.shouldClear(
            loadedRange: .week,
            requestedRange: .week))
        #expect(HistoricalReloadPolicy.shouldClear(
            loadedRange: .week,
            requestedRange: .allTime))
        #expect(HistoricalReloadPolicy.shouldClear(
            loadedRange: nil,
            requestedRange: .week))
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

private actor SelectorStoreGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var loadWaiter: CheckedContinuation<[AppEnergy], Never>?
    private var result: [AppEnergy]?

    func load() async -> [AppEnergy] {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        return await withCheckedContinuation { continuation in
            if let result {
                self.result = nil
                continuation.resume(returning: result)
            } else {
                loadWaiter = continuation
            }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release(with result: [AppEnergy]) {
        if let loadWaiter {
            self.loadWaiter = nil
            loadWaiter.resume(returning: result)
        } else {
            self.result = result
        }
    }
}

private actor SelectorLiveGate: EnergySource {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var loadWaiter: CheckedContinuation<[AppEnergy], Error>?
    private var result: Result<[AppEnergy], Error>?

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                self.result = nil
                continuation.resume(with: result)
            } else {
                loadWaiter = continuation
            }
        }
    }

    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample] {
        []
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func fail(with error: Error) {
        let result: Result<[AppEnergy], Error> = .failure(error)
        if let loadWaiter {
            self.loadWaiter = nil
            loadWaiter.resume(with: result)
        } else {
            self.result = result
        }
    }
}

private actor SelectorFailureReporter {
    private(set) var callCount = 0

    func record() {
        callCount += 1
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
