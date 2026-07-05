import Foundation
import Testing
@testable import JuiceCore

private func makeStore() throws -> JuiceStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("juice-test-\(UUID().uuidString).sqlite").path
    return try JuiceStore(path: path)
}

@Suite struct StoreTests {
    @Test func insertAndReadSamplesSinceCutoff() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try store.insertSample(
            ts: now.addingTimeInterval(-7200), percent: 90,
            onAC: true, isCharging: true, watts: -30.0)
        try store.insertSample(
            ts: now.addingTimeInterval(-1800), percent: 80,
            onAC: false, isCharging: false, watts: 12.5)
        try store.insertSample(
            ts: now, percent: 78,
            onAC: false, isCharging: false, watts: 10.0)

        let samples = try store.samples(since: now.addingTimeInterval(-3600))
        #expect(samples.count == 2)
        #expect(samples[0].percent == 80)
        #expect(samples[0].onAC == false)
        #expect(samples[0].isCharging == false)
        #expect(abs(samples[0].watts - 12.5) < 1e-9)
        #expect(abs(samples[0].date.timeIntervalSince1970
            - now.addingTimeInterval(-1800).timeIntervalSince1970) < 1e-6)
        #expect(samples[1].percent == 78)
    }

    @Test func upsertRollupReplacesSameDayAndAppKey() throws {
        let store = try makeStore()

        try store.upsertRollups([
            DailyEnergyRollup(day: "2026-07-01", appKey: "com.example.app", wh: 1.0, cpuHours: 0.5),
            DailyEnergyRollup(day: "2026-07-01", appKey: "com.other.app", wh: 2.0, cpuHours: 0.25),
        ])
        try store.upsertRollups([
            DailyEnergyRollup(day: "2026-07-01", appKey: "com.example.app", wh: 3.5, cpuHours: 1.5)
        ])

        let rollups = try store.rollups(sinceDay: "2026-07-01")
        #expect(rollups.count == 2)
        let example = try #require(rollups.first { $0.appKey == "com.example.app" })
        #expect(abs(example.wh - 3.5) < 1e-9)
        #expect(abs(example.cpuHours - 1.5) < 1e-9)
    }

    @Test func rollupsFilterBySinceDay() throws {
        let store = try makeStore()
        try store.upsertRollups([
            DailyEnergyRollup(day: "2026-06-30", appKey: "a", wh: 1, cpuHours: 1),
            DailyEnergyRollup(day: "2026-07-01", appKey: "a", wh: 2, cpuHours: 2),
        ])
        let rollups = try store.rollups(sinceDay: "2026-07-01")
        #expect(rollups.count == 1)
        #expect(rollups[0].day == "2026-07-01")
    }

    @Test func watermarkRoundTrip() throws {
        let store = try makeStore()
        #expect(try store.watermark() == nil)

        let first = Date(timeIntervalSince1970: 1_750_000_000)
        try store.setWatermark(first)
        let readBack = try #require(try store.watermark())
        #expect(abs(readBack.timeIntervalSince1970 - first.timeIntervalSince1970) < 1e-6)

        let second = first.addingTimeInterval(900)
        try store.setWatermark(second)
        let updated = try #require(try store.watermark())
        #expect(abs(updated.timeIntervalSince1970 - second.timeIntervalSince1970) < 1e-6)
    }

    @Test func earliestRollupDayReturnsMinDay() throws {
        let store = try makeStore()
        #expect(try store.earliestRollupDay() == nil)

        try store.upsertRollups([
            DailyEnergyRollup(day: "2026-07-02", appKey: "a", wh: 1, cpuHours: 1),
            DailyEnergyRollup(day: "2026-06-30", appKey: "b", wh: 2, cpuHours: 2),
            DailyEnergyRollup(day: "2026-07-01", appKey: "a", wh: 3, cpuHours: 3),
        ])
        #expect(try store.earliestRollupDay() == "2026-06-30")
    }

    @Test func rollupDayCountCountsDistinctDaysSince() throws {
        let store = try makeStore()
        #expect(try store.rollupDayCount(sinceDay: "2026-01-01") == 0)

        try store.upsertRollups([
            DailyEnergyRollup(day: "2026-06-30", appKey: "a", wh: 1, cpuHours: 1),
            DailyEnergyRollup(day: "2026-07-01", appKey: "a", wh: 2, cpuHours: 2),
            DailyEnergyRollup(day: "2026-07-01", appKey: "b", wh: 3, cpuHours: 3),
            DailyEnergyRollup(day: "2026-07-02", appKey: "a", wh: 4, cpuHours: 4),
        ])
        #expect(try store.rollupDayCount(sinceDay: "2026-07-01") == 2)
        #expect(try store.rollupDayCount(sinceDay: "2026-06-01") == 3)
        #expect(try store.rollupDayCount(sinceDay: "2026-07-03") == 0)
    }

    @Test func backfillSamplesReadBackAlongsideLiveSamples() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try store.insertSample(
            ts: now, percent: 60, onAC: false, isCharging: false, watts: 8)
        try store.insertBackfillSamples([
            (ts: now.addingTimeInterval(-600), percent: 62,
             onAC: false, isCharging: false, watts: 7.5),
            (ts: now.addingTimeInterval(-300), percent: 61,
             onAC: true, isCharging: true, watts: -20),
        ])

        let samples = try store.samples(
            since: now.addingTimeInterval(-3600), until: now)
        #expect(samples.count == 3)
        #expect(samples.map(\.percent) == [62, 61, 60])
        #expect(samples[1].onAC == true)
        #expect(samples[1].isCharging == true)
        #expect(abs(samples[1].watts - -20) < 1e-9)
    }

    @Test func insertBackfillSamplesWithEmptyInputIsANoOp() throws {
        let store = try makeStore()
        try store.insertBackfillSamples([])
        #expect(try store.samples(since: .distantPast).isEmpty)
    }

    @Test func sampleTimestampsReturnsSortedWindowedTimestamps() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try store.insertSample(
            ts: now.addingTimeInterval(-7200), percent: 90,
            onAC: false, isCharging: false, watts: 5)
        try store.insertSample(
            ts: now, percent: 80, onAC: false, isCharging: false, watts: 5)
        try store.insertBackfillSamples([
            (ts: now.addingTimeInterval(-1800), percent: 85,
             onAC: false, isCharging: false, watts: 5)
        ])

        let timestamps = try store.sampleTimestamps(
            since: now.addingTimeInterval(-3600), until: now)
        #expect(timestamps == [
            now.addingTimeInterval(-1800).timeIntervalSince1970,
            now.timeIntervalSince1970,
        ])
    }

    @Test func metaDateRoundTripsPerKey() throws {
        let store = try makeStore()
        #expect(try store.metaDate(forKey: "backfill_last_run") == nil)

        let first = Date(timeIntervalSince1970: 1_750_000_000)
        try store.setMetaDate(first, forKey: "backfill_last_run")
        let readBack = try #require(try store.metaDate(forKey: "backfill_last_run"))
        #expect(abs(readBack.timeIntervalSince1970 - first.timeIntervalSince1970) < 1e-6)

        // Keys are independent: the rollup watermark is untouched.
        #expect(try store.watermark() == nil)

        let second = first.addingTimeInterval(3600)
        try store.setMetaDate(second, forKey: "backfill_last_run")
        let updated = try #require(try store.metaDate(forKey: "backfill_last_run"))
        #expect(abs(updated.timeIntervalSince1970 - second.timeIntervalSince1970) < 1e-6)
    }

    @Test func pruneRemovesOnlyOldSamples() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try store.insertSample(
            ts: now.addingTimeInterval(-100 * 24 * 3600), percent: 50,
            onAC: false, isCharging: false, watts: 5)
        try store.insertSample(
            ts: now, percent: 60, onAC: false, isCharging: false, watts: 6)

        try store.pruneSamples(olderThan: now.addingTimeInterval(-90 * 24 * 3600))

        let remaining = try store.samples(since: .distantPast)
        #expect(remaining.count == 1)
        #expect(remaining[0].percent == 60)
    }
}
