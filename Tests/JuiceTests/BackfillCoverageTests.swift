import Foundation
import Testing
@testable import JuiceCore

@Suite struct BackfillCoverageTests {
    private let windowStart: Double = 10_000
    private let windowEnd: Double = 20_000

    /// Filters candidate timestamps the way SamplerService does, so tests
    /// exercise exactly the insertion rule backfill uses.
    private func inserted(
        candidates: [Double], existing: [Double]
    ) -> [Double] {
        let regions = BackfillCoverage.uncoveredRegions(
            existing: existing, windowStart: windowStart, windowEnd: windowEnd)
        return candidates.filter { BackfillCoverage.contains(regions, $0) }
    }

    @Test func emptyExistingUncoversWholeWindow() {
        let regions = BackfillCoverage.uncoveredRegions(
            existing: [], windowStart: windowStart, windowEnd: windowEnd)
        #expect(regions == [
            BackfillCoverage.Region(
                start: windowStart, end: windowEnd,
                includesStart: true, includesEnd: true)
        ])
        // Window edges are inclusive when unbounded by samples.
        #expect(BackfillCoverage.contains(regions, windowStart))
        #expect(BackfillCoverage.contains(regions, windowEnd))
        #expect(!BackfillCoverage.contains(regions, windowStart - 1))
        #expect(!BackfillCoverage.contains(regions, windowEnd + 1))
    }

    @Test func overlapWithExistingCoverageIsExcluded() {
        // Existing samples cover 12_000...12_120 densely (60s apart).
        let existing: [Double] = [12_000, 12_060, 12_120]
        // Candidates inside the covered run, including exact matches, are
        // never inserted.
        let result = inserted(
            candidates: [12_000, 12_030, 12_060, 12_090, 12_120],
            existing: existing)
        #expect(result.isEmpty)
    }

    @Test func beforeFirstSampleIsFilled() {
        let existing: [Double] = [15_000, 15_060]
        let result = inserted(
            candidates: [10_000, 12_000, 14_999, 15_000, 15_030],
            existing: existing)
        // Everything strictly before the first sample (and at the window
        // start) is uncovered; the first sample's own timestamp is not.
        #expect(result == [10_000, 12_000, 14_999])
    }

    @Test func gapBetweenSamplesIsFilled() {
        // 15_000 -> 18_000 is a 3000s gap, far above the 120s threshold.
        let existing: [Double] = [
            windowStart, windowStart + 60, 15_000, 18_000, windowEnd,
        ]
        let result = inserted(
            candidates: [15_000, 15_500, 16_000, 17_999, 18_000],
            existing: existing)
        // Gap interior is filled; the bounding samples themselves are not.
        #expect(result == [15_500, 16_000, 17_999])
    }

    @Test func smallGapsAreNotUncovered() {
        // 120s apart exactly: not a gap (threshold is strictly greater-than,
        // matching ChartSegmentation).
        let existing: [Double] = [windowStart, windowStart + 120]
        let regions = BackfillCoverage.uncoveredRegions(
            existing: existing, windowStart: windowStart, windowEnd: windowStart + 120)
        #expect(regions.isEmpty)
    }

    @Test func afterLastSampleIsFilled() {
        let existing: [Double] = [windowStart, windowStart + 60]
        let result = inserted(
            candidates: [windowStart + 60, windowStart + 61, windowEnd],
            existing: existing)
        #expect(result == [windowStart + 61, windowEnd])
    }

    @Test func samplesOutsideWindowAreIgnored() {
        let existing: [Double] = [windowStart - 500, windowEnd + 500]
        let regions = BackfillCoverage.uncoveredRegions(
            existing: existing, windowStart: windowStart, windowEnd: windowEnd)
        #expect(regions == [
            BackfillCoverage.Region(
                start: windowStart, end: windowEnd,
                includesStart: true, includesEnd: true)
        ])
    }

    @Test func invertedWindowUncoversNothing() {
        let regions = BackfillCoverage.uncoveredRegions(
            existing: [], windowStart: windowEnd, windowEnd: windowStart)
        #expect(regions.isEmpty)
    }

    @Test func secondRunInsertsNothing() {
        // Live sampler covered the middle; powerlog has points everywhere.
        let live: [Double] = [14_000, 14_060, 14_120]
        let candidates: [Double] = stride(
            from: windowStart, through: windowEnd, by: 300
        ).map { $0 }

        let firstRun = inserted(candidates: candidates, existing: live)
        #expect(!firstRun.isEmpty)

        // After inserting, the store holds live + backfilled timestamps.
        let afterFirst = (live + firstRun).sorted()
        let secondRun = inserted(candidates: candidates, existing: afterFirst)
        #expect(secondRun.isEmpty)
    }
}
