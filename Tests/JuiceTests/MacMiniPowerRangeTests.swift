import Foundation
import Testing
@testable import Juice
@testable import JuiceCore

@Suite("Mac mini power ranges")
struct MacMiniPowerRangeTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Server mode exposes Today, one week, and All")
    func visibleRanges() {
        #expect(macMiniPowerRanges == [.today, .week, .allTime])
        #expect(macMiniPowerRanges.map(\.macMiniPickerLabel) == ["Today", "1W", "All"])
    }

    @Test("All starts at the first recorded power sample")
    func allUsesRecordingStart() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSample = now.addingTimeInterval(-40 * 24 * 3600)

        #expect(EnergyRange.allTime.macMiniWindowStart(
            now: now,
            recordingSince: firstSample,
            calendar: utcCalendar) == firstSample)
    }

    @Test("Week covers seven calendar days including today")
    func weekUsesSevenCalendarDays() {
        let now = Date(timeIntervalSince1970: 1_800_043_210)
        let start = EnergyRange.week.macMiniWindowStart(
            now: now,
            recordingSince: nil,
            calendar: utcCalendar)
        let todayStart = utcCalendar.startOfDay(for: now)

        #expect(start == utcCalendar.date(byAdding: .day, value: -6, to: todayStart))
    }

    @Test("All adapts chart resolution to recorded history")
    func allBucketResolution() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(EnergyRange.allTime.macMiniBucketDuration(
            windowStart: now.addingTimeInterval(-20 * 24 * 3600),
            now: now) == 3600)
        #expect(EnergyRange.allTime.macMiniBucketDuration(
            windowStart: now.addingTimeInterval(-90 * 24 * 3600),
            now: now) == 6 * 3600)
        #expect(EnergyRange.allTime.macMiniBucketDuration(
            windowStart: now.addingTimeInterval(-365 * 24 * 3600),
            now: now) == 24 * 3600)
    }

    @Test("Shared loader applies one range to system and app data")
    func loaderRangeConsistency() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-server-loader-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let now = utcCalendar.date(
            from: DateComponents(
                calendar: utcCalendar,
                timeZone: utcCalendar.timeZone,
                year: 2027,
                month: 1,
                day: 10,
                hour: 12))!
        let todayStart = utcCalendar.startOfDay(for: now)
        let fiveDaysAgo = utcCalendar.date(
            byAdding: .day,
            value: -5,
            to: todayStart)!
        let eightDaysAgo = utcCalendar.date(
            byAdding: .day,
            value: -8,
            to: todayStart)!

        try store.insertSystemPowerSample(
            ts: todayStart.addingTimeInterval(60),
            watts: 10)
        try store.insertSystemPowerSample(
            ts: todayStart.addingTimeInterval(120),
            watts: 12)
        try store.insertSystemPowerSample(ts: fiveDaysAgo, watts: 8)
        try store.insertSystemPowerSample(ts: eightDaysAgo, watts: 6)
        try store.addSystemAppEnergy([
            StoredSystemAppEnergyBucket(
                bucketStart: todayStart,
                appKey: "today",
                displayName: "Today App",
                energyWh: 1,
                activeDuration: 600,
                peakWatts: 12),
            StoredSystemAppEnergyBucket(
                bucketStart: fiveDaysAgo,
                appKey: "week",
                displayName: "Week App",
                energyWh: 2,
                activeDuration: 900,
                peakWatts: 8),
            StoredSystemAppEnergyBucket(
                bucketStart: eightDaysAgo,
                appKey: "old",
                displayName: "Old App",
                energyWh: 3,
                activeDuration: 1200,
                peakWatts: 6),
        ])

        let today = try MacMiniPowerDataLoader.load(
            store: store,
            range: .today,
            now: now,
            calendar: utcCalendar)
        let week = try MacMiniPowerDataLoader.load(
            store: store,
            range: .week,
            now: now,
            calendar: utcCalendar)
        let all = try MacMiniPowerDataLoader.load(
            store: store,
            range: .allTime,
            now: now,
            calendar: utcCalendar)

        #expect(today.summary.sampleCount == 2)
        #expect(today.appTotals.map(\.appKey) == ["today"])
        #expect(week.summary.sampleCount == 3)
        #expect(Set(week.appTotals.map(\.appKey)) == ["today", "week"])
        #expect(all.summary.sampleCount == 4)
        #expect(Set(all.appTotals.map(\.appKey)) == ["today", "week", "old"])
    }
}
