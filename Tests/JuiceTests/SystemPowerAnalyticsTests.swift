import Foundation
import Testing
@testable import JuiceCore

@Suite("System power analytics")
struct SystemPowerAnalyticsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ seconds: TimeInterval, watts: Double) -> StoredSystemPowerSample {
        StoredSystemPowerSample(date: t0.addingTimeInterval(seconds), watts: watts)
    }

    @Test("Constant load produces time-weighted watts and watt-hours")
    func constantLoad() {
        let samples = (0...10).map { sample(Double($0) * 60, watts: 10) }
        let summary = SystemPowerAnalytics.summary(
            samples: samples,
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(10 * 60))

        #expect(summary.averageWatts == 10)
        #expect(abs(summary.energyWh - (10.0 / 6.0)) < 1e-9)
        #expect(summary.peakWatts == 10)
        #expect(summary.coveredDuration == 600)
        #expect(summary.coverageFraction == 1)
        #expect(summary.sampleCount == 11)
    }

    @Test("Load changes are integrated with a trapezoid")
    func trapezoidalIntegration() {
        let summary = SystemPowerAnalytics.summary(
            samples: [
                sample(0, watts: 10),
                sample(60, watts: 20),
            ],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(60))

        #expect(summary.averageWatts == 15)
        #expect(abs(summary.energyWh - 0.25) < 1e-9)
        #expect(summary.peakWatts == 20)
    }

    @Test("Long gaps are excluded from energy and coverage")
    func gapsAreNotInvented() {
        let summary = SystemPowerAnalytics.summary(
            samples: [
                sample(0, watts: 12),
                sample(60, watts: 12),
                sample(600, watts: 12),
                sample(660, watts: 12),
            ],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(660),
            maximumGap: 5 * 60)

        #expect(summary.averageWatts == 12)
        #expect(abs(summary.energyWh - 0.4) < 1e-9)
        #expect(summary.coveredDuration == 120)
        #expect(abs(summary.coverageFraction - (120.0 / 660.0)) < 1e-9)
    }

    @Test("Buckets preserve empty gaps")
    func buckets() {
        let buckets = SystemPowerAnalytics.buckets(
            samples: [
                sample(0, watts: 10),
                sample(60, watts: 20),
                sample(15 * 60, watts: 40),
                sample(45 * 60, watts: 80),
            ],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(60 * 60),
            bucketDuration: 15 * 60)

        #expect(buckets.map(\.start) == [t0])
        #expect(buckets.map(\.averageWatts) == [15])
        #expect(buckets.map(\.peakWatts) == [20])
        #expect(buckets.map(\.sampleCount) == [1])
    }

    @Test("Bucket averages are time weighted under uneven scheduling")
    func timeWeightedBuckets() throws {
        let buckets = SystemPowerAnalytics.buckets(
            samples: [
                sample(0, watts: 0),
                sample(60, watts: 60),
                sample(240, watts: 60),
            ],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(5 * 60),
            bucketDuration: 5 * 60)

        let bucket = try #require(buckets.first)
        #expect(buckets.count == 1)
        #expect(abs(bucket.averageWatts - 52.5) < 1e-9)
        #expect(bucket.peakWatts == 60)
        #expect(bucket.sampleCount == 2)
    }

    @Test("Segments are split and interpolated at bucket boundaries")
    func splitsBucketBoundaries() {
        let buckets = SystemPowerAnalytics.buckets(
            samples: [
                sample(4 * 60, watts: 0),
                sample(6 * 60, watts: 60),
            ],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(10 * 60),
            bucketDuration: 5 * 60)

        #expect(buckets.map(\.start) == [
            t0,
            t0.addingTimeInterval(5 * 60),
        ])
        #expect(buckets.map(\.averageWatts) == [15, 45])
        #expect(buckets.map(\.peakWatts) == [30, 60])
    }

    @Test("Minute aggregates retain exact energy, coverage, and peak")
    func minuteAggregates() throws {
        let aggregate = StoredSystemPowerSample(
            date: t0,
            watts: 1,
            coveredDuration: 60,
            energyWh: 1.0 / 60,
            peakWatts: 60,
            coverageStart: t0,
            coverageEnd: t0.addingTimeInterval(60))
        let summary = SystemPowerAnalytics.summary(
            samples: [aggregate],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(60))
        let bucket = try #require(SystemPowerAnalytics.buckets(
            samples: [aggregate],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(60),
            bucketDuration: 60).first)

        #expect(abs(summary.energyWh - (1.0 / 60)) < 1e-9)
        #expect(summary.averageWatts == 1)
        #expect(summary.peakWatts == 60)
        #expect(summary.coveredDuration == 60)
        #expect(bucket.averageWatts == 1)
        #expect(bucket.peakWatts == 60)
    }

    @Test("Partial current minute is not scaled down twice")
    func partialMinuteAggregate() {
        let end = t0.addingTimeInterval(30)
        let aggregate = StoredSystemPowerSample(
            date: t0,
            watts: 10,
            coveredDuration: 30,
            energyWh: 10.0 / 120,
            peakWatts: 20,
            coverageStart: t0,
            coverageEnd: end)
        let summary = SystemPowerAnalytics.summary(
            samples: [aggregate],
            windowStart: t0,
            windowEnd: end)

        #expect(abs(summary.energyWh - (10.0 / 120)) < 1e-9)
        #expect(summary.averageWatts == 10)
        #expect(summary.coveredDuration == 30)
        #expect(summary.peakWatts == 20)
    }

    @Test("Coarse buckets retain gaps between minute aggregates")
    func coarseBucketsRetainInternalGaps() {
        func aggregate(_ seconds: TimeInterval) -> StoredSystemPowerSample {
            let start = t0.addingTimeInterval(seconds)
            return StoredSystemPowerSample(
                date: start,
                watts: 10,
                coveredDuration: 60,
                energyWh: 10.0 / 60,
                peakWatts: 10,
                coverageStart: start,
                coverageEnd: start.addingTimeInterval(60))
        }

        let buckets = SystemPowerAnalytics.buckets(
            samples: [
                aggregate(0),
                aggregate(10 * 60),
            ],
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(15 * 60),
            bucketDuration: 15 * 60)

        #expect(buckets.count == 2)
        #expect(buckets.map(\.start) == [t0, t0])
        #expect(buckets.map(\.continuity) == [0, 1])
    }
}

@Suite("System app energy analytics")
struct SystemAppEnergyAnalyticsTests {
    private func reading(_ apps: [(String, String, Double)]) -> LivePowerReading {
        let appReadings = apps.map {
            AppPowerReading(
                appKey: $0.0,
                bundlePath: nil,
                displayName: $0.1,
                watts: $0.2)
        }
        return LivePowerReading(
            apps: appReadings,
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: appReadings.reduce(0) { $0 + $1.watts },
            systemWatts: 0)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Per-app watts integrate into hour buckets")
    func integratesApps() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let increments = SystemAppEnergyAnalytics.increments(
            previous: reading([("com.apple.Safari", "Safari", 6)]),
            current: reading([("com.apple.Safari", "Safari", 10)]),
            start: start,
            end: start.addingTimeInterval(60),
            calendar: utcCalendar)

        let safari = try #require(increments.first)
        #expect(safari.appKey == "com.apple.Safari")
        #expect(abs(safari.energyWh - (8.0 / 60.0)) < 1e-9)
        #expect(safari.activeDuration == 60)
        #expect(safari.peakWatts == 10)
    }

    @Test("App launches and exits taper from or to zero")
    func launchAndExit() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let launched = SystemAppEnergyAnalytics.increments(
            previous: reading([]),
            current: reading([("app", "App", 12)]),
            start: start,
            end: start.addingTimeInterval(60),
            calendar: utcCalendar)
        let exited = SystemAppEnergyAnalytics.increments(
            previous: reading([("app", "App", 12)]),
            current: reading([]),
            start: start.addingTimeInterval(60),
            end: start.addingTimeInterval(120),
            calendar: utcCalendar)

        #expect(abs(try #require(launched.first).energyWh - 0.1) < 1e-9)
        #expect(abs(try #require(exited.first).energyWh - 0.1) < 1e-9)
    }

    @Test("Intervals split across hour boundaries without changing energy")
    func splitsHours() {
        let hour = utcCalendar.date(
            from: DateComponents(
                calendar: utcCalendar,
                timeZone: utcCalendar.timeZone,
                year: 2027,
                month: 1,
                day: 1,
                hour: 10))!
        let start = hour.addingTimeInterval(59 * 60 + 30)
        let increments = SystemAppEnergyAnalytics.increments(
            previous: reading([("app", "App", 6)]),
            current: reading([("app", "App", 6)]),
            start: start,
            end: start.addingTimeInterval(60),
            calendar: utcCalendar)

        #expect(increments.count == 2)
        #expect(abs(increments.reduce(0) { $0 + $1.energyWh } - 0.1) < 1e-9)
        #expect(increments.map(\.activeDuration) == [30, 30])
    }

    @Test("Long server gaps do not invent app energy")
    func excludesGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let increments = SystemAppEnergyAnalytics.increments(
            previous: reading([("app", "App", 10)]),
            current: reading([("app", "App", 10)]),
            start: start,
            end: start.addingTimeInterval(6 * 60),
            calendar: utcCalendar)

        #expect(increments.isEmpty)
    }

    @Test("Apps below the display threshold still persist energy")
    func includesAttributedIdleApps() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let idleApp = AppPowerReading(
            appKey: "quiet.app",
            bundlePath: nil,
            displayName: "Quiet App",
            watts: 0.04)
        let reading = LivePowerReading(
            apps: [],
            attributedApps: [idleApp],
            idleAppCount: 1,
            idleWatts: idleApp.watts,
            totalAppWatts: idleApp.watts,
            systemWatts: 0)

        let increments = SystemAppEnergyAnalytics.increments(
            previous: reading,
            current: reading,
            start: start,
            end: start.addingTimeInterval(60),
            calendar: utcCalendar)

        let persisted = try #require(increments.first)
        #expect(increments.count == 1)
        #expect(persisted.appKey == idleApp.appKey)
        #expect(abs(persisted.energyWh - idleApp.watts / 60) < 1e-9)
    }
}
