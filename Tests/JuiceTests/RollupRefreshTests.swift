import Foundation
import Testing
import JuiceXPCShared
@testable import JuiceCore

/// Regression tests for the full-day rollup rebuild: every refresh fetches
/// each covered day from its local start and replaces that day's rows with a
/// complete recomputation, so a later refresh must never shrink a stored
/// day's total to the newest slice.
@Suite struct RollupRefreshTests {
    /// A fixed calendar so day boundaries do not depend on the machine's zone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeStore() throws -> JuiceStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-test-\(UUID().uuidString).sqlite").path
        return try JuiceStore(path: path)
    }

    private func epoch(_ year: Int, _ month: Int, _ day: Int, hour: Int) -> Double {
        let components = DateComponents(year: year, month: month, day: day, hour: hour)
        return utcCalendar.date(from: components)!.timeIntervalSince1970
    }

    private func interval(
        start: Double, energyNJ: Double, appKey: String = "com.example.app"
    ) -> EnergyInterval {
        EnergyInterval(
            start: start, end: start + 300,
            bundleID: appKey, launchdName: nil,
            energyNJ: energyNJ, gpuEnergyNJ: 0, aneEnergyNJ: 0, cpuTime: 0)
    }

    /// Mimics one sampler refresh: aggregate the fetched intervals and replace
    /// the rows of exactly the days they cover.
    private func refresh(_ store: JuiceStore, intervals: [EnergyInterval]) throws {
        let rollups = RollupBuilder.dailyRollups(from: intervals, calendar: utcCalendar)
        try store.replaceRollups(rollups, coveringDays: Set(rollups.map(\.day)))
    }

    private func wh(_ store: JuiceStore, day: String) throws -> Double {
        try store.rollups(sinceDay: day)
            .filter { $0.day == day }
            .reduce(0) { $0 + $1.wh }
    }

    @Test func laterRefreshesKeepFullDayTotalsAndAccumulateNewDays() throws {
        let store = try makeStore()

        // Day 1 in full: 0.5 Wh in the morning + 0.5 Wh in the evening.
        let day1Fetch = [
            interval(start: epoch(2026, 7, 1, hour: 9), energyNJ: 1.8e12),
            interval(start: epoch(2026, 7, 1, hour: 21), energyNJ: 1.8e12),
        ]
        try refresh(store, intervals: day1Fetch)
        #expect(abs(try wh(store, day: "2026-07-01") - 1.0) < 1e-9)

        // Next refresh re-fetches day 1 from its start plus day 2 so far.
        // Day 1 must keep its full-day total, not collapse to the new slice.
        let day2Morning = interval(start: epoch(2026, 7, 2, hour: 10), energyNJ: 1.8e12)
        try refresh(store, intervals: day1Fetch + [day2Morning])
        #expect(abs(try wh(store, day: "2026-07-01") - 1.0) < 1e-9)
        #expect(abs(try wh(store, day: "2026-07-02") - 0.5) < 1e-9)

        // A third refresh sees more of day 2 (including a second app): day 2
        // accumulates and day 1 is still intact.
        let day2Evening = interval(
            start: epoch(2026, 7, 2, hour: 20), energyNJ: 3.6e12, appKey: "com.other.app")
        try refresh(store, intervals: day1Fetch + [day2Morning, day2Evening])
        #expect(abs(try wh(store, day: "2026-07-01") - 1.0) < 1e-9)
        #expect(abs(try wh(store, day: "2026-07-02") - 1.5) < 1e-9)
    }

    @Test func replaceRollupsDropsStaleAppRowsForCoveredDays() throws {
        let store = try makeStore()
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 1, hour: 9), energyNJ: 1.8e12, appKey: "a"),
            interval(start: epoch(2026, 7, 1, hour: 9), energyNJ: 1.8e12, appKey: "b"),
        ])
        // The rebuild no longer sees app "b" for that day; its row must go.
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 1, hour: 9), energyNJ: 1.8e12, appKey: "a")
        ])
        let rollups = try store.rollups(sinceDay: "2026-07-01")
        #expect(rollups.map(\.appKey) == ["a"])
    }

    @Test func replaceRollupsLeavesUncoveredDaysAlone() throws {
        let store = try makeStore()
        try refresh(store, intervals: [
            interval(start: epoch(2026, 6, 30, hour: 12), energyNJ: 3.6e12)
        ])
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 1, hour: 12), energyNJ: 1.8e12)
        ])
        #expect(abs(try wh(store, day: "2026-06-30") - 1.0) < 1e-9)
        #expect(abs(try wh(store, day: "2026-07-01") - 0.5) < 1e-9)
    }

    @Test func pruneRollupsRemovesOnlyDaysBeforeCutoff() throws {
        let store = try makeStore()
        try store.upsertRollups([
            DailyEnergyRollup(day: "2025-07-01", appKey: "a", wh: 1, cpuHours: 1),
            DailyEnergyRollup(day: "2026-07-01", appKey: "a", wh: 2, cpuHours: 2),
        ])
        try store.pruneRollups(olderThanDay: "2026-07-01")
        let remaining = try store.rollups(sinceDay: "0000-00-00")
        #expect(remaining.map(\.day) == ["2026-07-01"])
    }
}
