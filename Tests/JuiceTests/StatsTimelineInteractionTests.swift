import Foundation
import Testing
@testable import Juice

@Suite("Stats timeline interaction")
struct StatsTimelineInteractionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ offset: TimeInterval,
        percent: Int = 50,
        onAC: Bool = false,
        isCharging: Bool = false
    ) -> BatterySample {
        BatterySample(
            date: start.addingTimeInterval(offset),
            percent: percent,
            onAC: onAC,
            isCharging: isCharging)
    }

    @Test("All means the full 90-day raw battery retention horizon")
    func viewportCatalog() {
        #expect(StatsTimelineViewport.allCases.map(\.label) == ["1D", "3D", "7D", "All"])
        #expect(StatsTimelineViewport.allCases.map(\.rawValue) == [24, 72, 168, 2_160])
        #expect(StatsTimelineViewport.all.duration == 90 * 24 * 3600)
        #expect(StatsTimelineViewport.all.accessibilityLabel == "All retained battery history")
    }

    @Test("selection finds the closest sample and prefers the earlier sample on a tie")
    func nearestSample() {
        let samples = [sample(0), sample(60), sample(120)]

        #expect(StatsTimelineInteraction.sampleIndex(
            nearest: start.addingTimeInterval(52),
            in: samples) == 1)
        #expect(StatsTimelineInteraction.sampleIndex(
            nearest: start.addingTimeInterval(90),
            in: samples) == 1)
    }

    @Test("selection reports no sample in the middle of a recording gap")
    func recordingGap() {
        let samples = [sample(0), sample(60), sample(600)]

        #expect(StatsTimelineInteraction.sampleIndex(
            nearest: start.addingTimeInterval(300),
            in: samples) == nil)
    }

    @Test("empty timelines have no selectable sample")
    func emptyTimeline() {
        #expect(StatsTimelineInteraction.sampleIndex(
            nearest: start,
            in: []) == nil)
    }

    @Test("latest viewport aligns its trailing edge with the timeline end")
    func latestViewport() {
        let end = start.addingTimeInterval(7 * 24 * 3600)

        #expect(StatsTimelineInteraction.latestScrollStart(
            windowStart: start,
            windowEnd: end,
            visibleDuration: 24 * 3600) == end.addingTimeInterval(-24 * 3600))
        #expect(StatsTimelineInteraction.latestScrollStart(
            windowStart: start,
            windowEnd: end,
            visibleDuration: 14 * 24 * 3600) == start)
    }

    @Test("All uses the full retained window while shorter ranges remain pageable")
    func longViewportMath() {
        let end = start.addingTimeInterval(90 * 24 * 3600)
        let week = StatsTimelineViewport.week.duration

        #expect(StatsTimelineInteraction.latestScrollStart(
            windowStart: start,
            windowEnd: end,
            visibleDuration: week) == end.addingTimeInterval(-week))
        #expect(StatsTimelineInteraction.shiftedScrollStart(
            end.addingTimeInterval(-week),
            pages: -1,
            windowStart: start,
            windowEnd: end,
            visibleDuration: week) == end.addingTimeInterval(-2 * week))
        #expect(StatsTimelineInteraction.latestScrollStart(
            windowStart: start,
            windowEnd: end,
            visibleDuration: StatsTimelineViewport.all.duration) == start)
    }

    @Test("narrow axis plans keep every range to a readable date-aware density")
    func narrowAxisPlans() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let expectations: [(StatsTimelineViewport, StatsTimelineAxisPlan, Int)] = [
            (.day, StatsTimelineAxisPlan(interval: .hour(6), labelStyle: .time), 5),
            (.threeDays, StatsTimelineAxisPlan(interval: .day(1), labelStyle: .weekdayDay), 4),
            (.week, StatsTimelineAxisPlan(interval: .day(2), labelStyle: .weekdayDay), 4),
            (.all, StatsTimelineAxisPlan(interval: .month(1), labelStyle: .monthDay), 4),
        ]

        for (viewport, expectedPlan, maximumTicks) in expectations {
            let plan = StatsTimelineInteraction.axisPlan(for: viewport, plotWidth: 280)
            let ticks = StatsTimelineInteraction.axisTickDates(
                plan: plan,
                visibleStart: start,
                visibleEnd: start.addingTimeInterval(viewport.duration),
                calendar: calendar)
            #expect(plan == expectedPlan)
            #expect(ticks.count >= 2)
            #expect(ticks.count <= maximumTicks)
            #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test("wider three-day charts use stacked half-day labels")
    func regularAxisPlan() {
        let plan = StatsTimelineInteraction.axisPlan(
            for: .threeDays,
            plotWidth: 500)
        #expect(plan == StatsTimelineAxisPlan(
            interval: .hour(12),
            labelStyle: .weekdayTime))
    }

    @Test("axis ticks too close to narrow plot edges are omitted")
    func axisEdgeInset() {
        let end = start.addingTimeInterval(24 * 3600)
        let ticks = [
            start.addingTimeInterval(30 * 60),
            start.addingTimeInterval(6 * 3600),
            start.addingTimeInterval(12 * 3600),
            end.addingTimeInterval(-30 * 60),
        ]

        let inset = StatsTimelineInteraction.insetAxisTicks(
            ticks,
            visibleStart: start,
            visibleEnd: end,
            plotWidth: 280)

        #expect(inset == [ticks[1], ticks[2]])
    }

    @Test("viewport start clamps to the available timeline")
    func viewportClamping() {
        let end = start.addingTimeInterval(7 * 24 * 3600)
        let duration = 3 * 24 * 3600.0

        #expect(StatsTimelineInteraction.clampedScrollStart(
            start.addingTimeInterval(-60),
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration) == start)
        #expect(StatsTimelineInteraction.clampedScrollStart(
            end,
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration) == end.addingTimeInterval(-duration))
    }

    @Test("paging moves by one visible window and clamps at both ends")
    func viewportPaging() {
        let end = start.addingTimeInterval(7 * 24 * 3600)
        let duration = 24 * 3600.0
        let latest = end.addingTimeInterval(-duration)

        #expect(StatsTimelineInteraction.shiftedScrollStart(
            latest,
            pages: -1,
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration) == latest.addingTimeInterval(-duration))
        #expect(StatsTimelineInteraction.shiftedScrollStart(
            start,
            pages: -1,
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration) == start)
        #expect(StatsTimelineInteraction.shiftedScrollStart(
            latest,
            pages: 1,
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration) == latest)
    }

    @Test("latest detection tolerates subsecond chart rounding")
    func latestDetectionTolerance() {
        let end = start.addingTimeInterval(7 * 24 * 3600)
        let duration = 24 * 3600.0
        let latest = end.addingTimeInterval(-duration)

        #expect(StatsTimelineInteraction.isAtLatest(
            latest.addingTimeInterval(-0.5),
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration))
        #expect(!StatsTimelineInteraction.isAtLatest(
            latest.addingTimeInterval(-2),
            windowStart: start,
            windowEnd: end,
            visibleDuration: duration))
    }

    @Test("large timelines reduce to a bounded, ordered extrema-preserving representation")
    func truthPreservingReduction() {
        var samples = (0..<11_012).map { index in
            sample(Double(index) * 40, percent: 30 + index % 50)
        }
        samples[2_001] = sample(Double(2_001) * 40, percent: 0)
        samples[8_007] = sample(Double(8_007) * 40, percent: 100)

        let segments = StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: StatsTimelinePreparedData.targetPointCount(
                for: StatsTimelineViewport.week.duration))
        let reduced = segments.flatMap { $0 }

        #expect(segments.count == 1)
        #expect(reduced.count <= StatsTimelinePreparedData.minimumTargetPointCount)
        #expect(reduced.first?.date == samples.first?.date)
        #expect(reduced.last?.date == samples.last?.date)
        #expect(reduced.contains { $0.percent == 0 })
        #expect(reduced.contains { $0.percent == 100 })
        #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test("render budgets scale through All's 90 days and remain capped")
    func durationScaledRenderBudgets() {
        #expect(StatsTimelinePreparedData.targetPointCount(
            for: StatsTimelineViewport.week.duration) == 1_200)
        #expect(StatsTimelinePreparedData.targetPointCount(
            for: StatsTimelineViewport.all.duration) == 6_000)
        #expect(StatsTimelinePreparedData.targetPointCount(
            for: 365 * 24 * 3600) == 6_000)
    }

    @Test("a minute-cadence 90-day timeline stays bounded and keeps extrema")
    func ninetyDayReduction() {
        var samples = (0..<(90 * 24 * 60)).map { index in
            sample(Double(index) * 60, percent: 20 + index % 61)
        }
        samples[10_000] = sample(Double(10_000) * 60, percent: 0)
        samples[100_000] = sample(Double(100_000) * 60, percent: 100)
        let target = StatsTimelinePreparedData.targetPointCount(
            for: StatsTimelineViewport.all.duration)

        let reduced = StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: target).flatMap { $0 }

        #expect(reduced.count <= target)
        #expect(reduced.contains { $0.percent == 0 })
        #expect(reduced.contains { $0.percent == 100 })
        #expect(reduced.first?.date == samples.first?.date)
        #expect(reduced.last?.date == samples.last?.date)
    }

    @Test("reduction keeps recording gaps as separate segments")
    func reductionPreservesGaps() {
        let samples = [sample(0), sample(60), sample(120), sample(600), sample(660)]

        let segments = StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: 4)

        #expect(segments.count == 2)
        #expect(segments.flatMap { $0 }.count == 4)
        #expect(segments[0].map(\.date) == [
            start,
            start.addingTimeInterval(120),
        ])
        #expect(segments[1].map(\.date) == [
            start.addingTimeInterval(600),
            start.addingTimeInterval(660),
        ])
        #expect(segments[0].last?.date == start.addingTimeInterval(120))
        #expect(segments[1].first?.date == start.addingTimeInterval(600))
    }

    @Test("fragmented reduction remains bounded without bridging gaps")
    func fragmentedReductionIsBounded() {
        let samples = (0..<10).map { index in
            sample(Double(index) * 600, percent: index == 4 ? 0 : (index == 7 ? 100 : 50))
        }

        let segments = StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: 4)
        let reduced = segments.flatMap { $0 }

        #expect(reduced.count == 4)
        #expect(segments.allSatisfy { $0.count == 1 })
        #expect(reduced.first?.date == samples.first?.date)
        #expect(reduced.last?.date == samples.last?.date)
        #expect(reduced.contains { $0.percent == 0 })
        #expect(reduced.contains { $0.percent == 100 })
        #expect(StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: 0).isEmpty)
    }

    @Test("small segment budgets preserve endpoints and an interior excursion")
    func smallSegmentBudget() {
        let samples = [
            sample(0, percent: 50),
            sample(60, percent: 10),
            sample(120, percent: 50),
            sample(180, percent: 50),
        ]

        let reduced = StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: 3).flatMap { $0 }

        #expect(reduced.count == 3)
        #expect(reduced.map(\.date) == [samples[0].date, samples[1].date, samples[3].date])
    }

    @Test("timeline refresh requests only the elapsed overlap after the initial load")
    func refreshRequestWindow() {
        #expect(StatsTimelineRefresh.requestHours(
            previousWindowEnd: nil,
            windowEnd: start,
            retentionHours: 2_160) == 2_160)
        #expect(StatsTimelineRefresh.requestHours(
            previousWindowEnd: start,
            windowEnd: start.addingTimeInterval(60),
            retentionHours: 2_160) == 1)
        #expect(StatsTimelineRefresh.requestHours(
            previousWindowEnd: start,
            windowEnd: start.addingTimeInterval(3 * 3600),
            retentionHours: 2_160) == 4)
        #expect(StatsTimelineRefresh.requestHours(
            previousWindowEnd: start,
            windowEnd: start.addingTimeInterval(3_000 * 3600),
            retentionHours: 2_160) == 2_160)
        #expect(StatsTimelineRefresh.requestHours(
            previousWindowEnd: start,
            windowEnd: start.addingTimeInterval(60),
            retentionHours: 2_160,
            historyRevisionChanged: true) == 7 * 24)
    }

    @Test("timeline refresh trims retention and replaces overlapping samples")
    func refreshMerge() {
        let existing = [
            sample(0, percent: 10),
            sample(60, percent: 20),
            sample(120, percent: 30),
            sample(120, percent: 29),
        ]
        let refreshed = [
            sample(120, percent: 30),
            sample(120, percent: 31),
            sample(180, percent: 40),
        ]

        let merged = StatsTimelineRefresh.mergedSamples(
            existing: existing,
            refreshed: refreshed,
            retentionStart: start.addingTimeInterval(60))

        #expect(merged.map(\.date) == [
            start.addingTimeInterval(60),
            start.addingTimeInterval(120),
            start.addingTimeInterval(180),
        ])
        #expect(merged.map(\.percent) == [20, 31, 40])
    }

    @Test("prepared data derives truthful gaps and power bands from full samples")
    func preparedDataPreservesStates() {
        let samples = [
            sample(0),
            sample(60, onAC: true, isCharging: true),
            sample(120, onAC: true, isCharging: true),
            sample(600, onAC: true),
        ]
        let prepared = StatsTimelinePreparedData(
            samples: samples,
            windowStart: start,
            windowEnd: start.addingTimeInterval(900))

        #expect(prepared.noDataRegions.contains {
            $0.start == start.addingTimeInterval(120)
                && $0.end == start.addingTimeInterval(600)
        })
        #expect(prepared.powerBands.map(\.state) == [.charging, .pluggedIn])
        #expect(prepared.samples.count == samples.count)
    }

    @Test("inspection deduplicates motion within a sample and within a no-data second")
    func inspectionDeduplication() {
        let samples = [sample(0), sample(60), sample(600)]

        let first = StatsTimelineInteraction.inspectionSelection(
            nearest: start.addingTimeInterval(5),
            in: samples)
        let sameSample = StatsTimelineInteraction.inspectionSelection(
            nearest: start.addingTimeInterval(20),
            in: samples)
        let gap = StatsTimelineInteraction.inspectionSelection(
            nearest: start.addingTimeInterval(300.1),
            in: samples)
        let sameGapSecond = StatsTimelineInteraction.inspectionSelection(
            nearest: start.addingTimeInterval(300.4),
            in: samples)

        #expect(first == sameSample)
        #expect(first.sampleIndex == 0)
        #expect(gap == sameGapSecond)
        #expect(gap.sampleIndex == nil)
    }
}
