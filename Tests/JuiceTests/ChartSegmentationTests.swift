import Foundation
import Testing
@testable import JuiceCore

private struct Point {
    var date: Date
    var onAC: Bool

    init(_ offset: TimeInterval, onAC: Bool = false) {
        self.date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
        self.onAC = onAC
    }
}

@Suite struct ChartSegmentationTests {
    @Test func gapOfExactlyMaxGapDoesNotSplit() {
        let points = [Point(0), Point(120), Point(240)]
        let segments = ChartSegmentation.segments(points, date: { $0.date })
        #expect(segments.count == 1)
        #expect(segments[0].count == 3)
    }

    @Test func gapJustOverMaxGapSplits() {
        let points = [Point(0), Point(60), Point(181), Point(241)]
        let segments = ChartSegmentation.segments(points, date: { $0.date })
        #expect(segments.count == 2)
        #expect(segments[0].map(\.date) == [points[0].date, points[1].date])
        #expect(segments[1].map(\.date) == [points[2].date, points[3].date])
    }

    @Test func emptyInputYieldsNoSegments() {
        let segments = ChartSegmentation.segments([Point](), date: { $0.date })
        #expect(segments.isEmpty)

        let runs = ChartSegmentation.acRuns(
            [Point](), date: { $0.date }, onAC: { $0.onAC })
        #expect(runs.isEmpty)
    }

    @Test func acRunBreaksAtEnclosedGapEvenWhenBothSidesOnAC() {
        let points = [
            Point(0, onAC: true),
            Point(60, onAC: true),
            // Gap of 540 s while still on AC: the run must break here.
            Point(600, onAC: true),
            Point(660, onAC: true),
            Point(720, onAC: false)
        ]
        let runs = ChartSegmentation.acRuns(
            points, date: { $0.date }, onAC: { $0.onAC })
        #expect(runs.count == 2)
        #expect(runs[0].start == points[0].date)
        #expect(runs[0].end == points[1].date)
        #expect(runs[1].start == points[2].date)
        #expect(runs[1].end == points[4].date)
    }

    @Test func acRunEndsAtFirstOffACSample() {
        let points = [
            Point(0, onAC: false),
            Point(60, onAC: true),
            Point(120, onAC: true),
            Point(180, onAC: false),
            Point(240, onAC: true)
        ]
        let runs = ChartSegmentation.acRuns(
            points, date: { $0.date }, onAC: { $0.onAC })
        #expect(runs.count == 2)
        #expect(runs[0].start == points[1].date)
        #expect(runs[0].end == points[3].date)
        // Trailing run ends at the last sample.
        #expect(runs[1].start == points[4].date)
        #expect(runs[1].end == points[4].date)
    }
}
