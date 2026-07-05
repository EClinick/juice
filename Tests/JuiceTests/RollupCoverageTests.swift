import Foundation
import Testing
import JuiceXPCShared
@testable import JuiceCore

/// Regression tests for the powerlog retention purge: the live powerlog keeps
/// only a few days, so a rebuild fetch can start mid-day for the oldest days
/// in the window. Such partially-covered days must never replace the store's
/// good full-day totals with the truncated remnants (observed in production:
/// a 76.7 Wh day collapsed to 0.2 Wh after a refresh).
@Suite struct RollupCoverageTests {
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

    /// Mimics one sampler refresh with the coverage guard: aggregate the
    /// fetched intervals, then replace only the days the source demonstrably
    /// covers from their local start. An empty fetch replaces nothing.
    private func refresh(_ store: JuiceStore, intervals: [EnergyInterval]) throws {
        guard let earliestStart = intervals.map(\.start).min() else { return }
        let rollups = RollupBuilder.dailyRollups(from: intervals, calendar: utcCalendar)
        let (covered, days) = RollupBuilder.fullyCoveredRollups(
            rollups,
            sourceCoverageStart: Date(timeIntervalSince1970: earliestStart),
            calendar: utcCalendar)
        try store.replaceRollups(covered, coveringDays: days)
    }

    private func wh(_ store: JuiceStore, day: String) throws -> Double {
        try store.rollups(sinceDay: day)
            .filter { $0.day == day }
            .reduce(0) { $0 + $1.wh }
    }

    @Test func purgedSourceDayDoesNotClobberStoredFullDayTotal() throws {
        let store = try makeStore()

        // Day 2 recorded in full while the powerlog still had it: 76.7 Wh.
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 2, hour: 0), energyNJ: 138.06e12),
            interval(start: epoch(2026, 7, 2, hour: 14), energyNJ: 138.06e12),
        ])
        #expect(abs(try wh(store, day: "2026-07-02") - 76.7) < 1e-9)

        // The powerlog has since purged everything before 22:00 on day 2, so
        // a later rebuild's fetch begins mid-day-2 with only tiny remnants,
        // plus day 3 in full. Day 2 must keep its stored total; day 3 is
        // replaced from the fetch.
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 2, hour: 22), energyNJ: 0.72e12),
            interval(start: epoch(2026, 7, 3, hour: 1), energyNJ: 100.0e12),
            interval(start: epoch(2026, 7, 3, hour: 15), energyNJ: 176.12e12),
        ])
        #expect(abs(try wh(store, day: "2026-07-02") - 76.7) < 1e-9)
        #expect(abs(try wh(store, day: "2026-07-03") - 76.7) < 1e-9)
    }

    @Test func emptyFetchReplacesNothing() throws {
        let store = try makeStore()
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 2, hour: 0), energyNJ: 3.6e12)
        ])
        try refresh(store, intervals: [])
        #expect(abs(try wh(store, day: "2026-07-02") - 1.0) < 1e-9)
    }

    @Test func fetchCoveringAllDaysFromTheirStartReplacesAll() throws {
        let store = try makeStore()
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 2, hour: 0), energyNJ: 3.6e12),
            interval(start: epoch(2026, 7, 3, hour: 9), energyNJ: 3.6e12),
        ])
        #expect(abs(try wh(store, day: "2026-07-02") - 1.0) < 1e-9)
        #expect(abs(try wh(store, day: "2026-07-03") - 1.0) < 1e-9)

        // The earliest fetched row sits exactly on day 2's local midnight, so
        // both days are fully covered and both stored totals are replaced.
        try refresh(store, intervals: [
            interval(start: epoch(2026, 7, 2, hour: 0), energyNJ: 1.8e12),
            interval(start: epoch(2026, 7, 3, hour: 9), energyNJ: 1.8e12),
        ])
        #expect(abs(try wh(store, day: "2026-07-02") - 0.5) < 1e-9)
        #expect(abs(try wh(store, day: "2026-07-03") - 0.5) < 1e-9)
    }

    @Test func fullyCoveredRollupsSplitsOnDayStartBoundary() {
        let rollups = [
            DailyEnergyRollup(day: "2026-07-02", appKey: "a", wh: 0.2, cpuHours: 0),
            DailyEnergyRollup(day: "2026-07-03", appKey: "a", wh: 50, cpuHours: 1),
            DailyEnergyRollup(day: "2026-07-03", appKey: "b", wh: 26.7, cpuHours: 1),
        ]
        // Coverage starts one second after day 2's midnight: day 2 is only
        // partially covered and must be dropped; day 3 survives in full.
        let coverageStart = Date(
            timeIntervalSince1970: epoch(2026, 7, 2, hour: 0) + 1)
        let (kept, days) = RollupBuilder.fullyCoveredRollups(
            rollups, sourceCoverageStart: coverageStart, calendar: utcCalendar)
        #expect(days == ["2026-07-03"])
        #expect(kept.map(\.appKey) == ["a", "b"])
        #expect(kept.allSatisfy { $0.day == "2026-07-03" })
    }
}
