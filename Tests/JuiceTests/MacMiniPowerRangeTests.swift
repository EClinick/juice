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

    @Test("Server Stats minimum height keeps its footer visible")
    func statsMinimumHeightIncludesFooter() {
        #expect(MacMiniStatsView.minimumContentHeight >= 560)
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

    @Test("All includes the first partial app-energy hour")
    func allIncludesFirstPartialAppHour() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-server-partial-hour-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let hourStart = utcCalendar.date(
            from: DateComponents(
                calendar: utcCalendar,
                timeZone: utcCalendar.timeZone,
                year: 2027,
                month: 1,
                day: 10,
                hour: 10))!
        let firstSample = hourStart.addingTimeInterval(35 * 60)
        let now = hourStart.addingTimeInterval(2 * 3600)

        try store.insertSystemPowerSample(ts: firstSample, watts: 8)
        try store.insertSystemPowerSample(
            ts: firstSample.addingTimeInterval(60),
            watts: 10)
        try store.addSystemAppEnergy([
            StoredSystemAppEnergyBucket(
                bucketStart: hourStart,
                appKey: "first-hour",
                displayName: "First Hour",
                energyWh: 0.25,
                activeDuration: 25 * 60,
                peakWatts: 10),
        ])

        let all = try MacMiniPowerDataLoader.load(
            store: store,
            range: .allTime,
            now: now,
            calendar: utcCalendar)

        #expect(all.recordingSince == firstSample)
        #expect(all.appTotals.map(\.appKey) == ["first-hour"])
        #expect(all.appTotals.first?.energyWh == 0.25)
    }

    @Test("Both server charts split recording gaps into separate segments")
    func chartSegmentsPreserveGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buckets = [
            SystemPowerBucket(
                start: start,
                averageWatts: 4,
                peakWatts: 5,
                sampleCount: 1),
            SystemPowerBucket(
                start: start.addingTimeInterval(60),
                averageWatts: 5,
                peakWatts: 6,
                sampleCount: 1),
            SystemPowerBucket(
                start: start.addingTimeInterval(10 * 60),
                averageWatts: 7,
                peakWatts: 8,
                sampleCount: 1),
        ]

        let points = MacMiniPowerChartSegments.points(
            buckets,
            bucketDuration: 60)

        #expect(points.map(\.segment) == [0, 0, 1])
    }

    @Test("Charts preserve gaps within one coarse bucket")
    func chartSegmentsPreserveInternalBucketGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buckets = [
            SystemPowerBucket(
                start: start,
                averageWatts: 4,
                peakWatts: 5,
                sampleCount: 1,
                continuity: 0),
            SystemPowerBucket(
                start: start,
                averageWatts: 7,
                peakWatts: 8,
                sampleCount: 1,
                continuity: 1),
        ]

        let points = MacMiniPowerChartSegments.points(
            buckets,
            bucketDuration: 15 * 60)

        #expect(points.map(\.segment) == [0, 1])
        #expect(Set(points.map(\.id)).count == 2)
    }
}
