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

private struct StatePoint {
    var date: Date
    var state: String

    init(_ offset: TimeInterval, _ state: String) {
        self.date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
        self.state = state
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

    @Test func stateChangeSplitsAStateRun() {
        let points = [
            StatePoint(0, "charging"),
            StatePoint(60, "charging"),
            StatePoint(120, "pluggedIn"),
            StatePoint(180, "pluggedIn")
        ]
        let runs = ChartSegmentation.stateRuns(
            points, date: { $0.date }, state: { $0.state })
        #expect(runs.count == 2)
        #expect(runs[0].state == "charging")
        #expect(runs[0].start == points[0].date)
        #expect(runs[0].end == points[1].date)
        #expect(runs[1].state == "pluggedIn")
        #expect(runs[1].start == points[2].date)
        #expect(runs[1].end == points[3].date)
    }

    @Test func gapSplitsAStateRunEvenWithSameState() {
        let points = [
            StatePoint(0, "charging"),
            StatePoint(60, "charging"),
            // Gap of 540 s with the same state: the run must break here.
            StatePoint(600, "charging"),
            StatePoint(660, "charging")
        ]
        let runs = ChartSegmentation.stateRuns(
            points, date: { $0.date }, state: { $0.state })
        #expect(runs.count == 2)
        #expect(runs[0].start == points[0].date)
        #expect(runs[0].end == points[1].date)
        #expect(runs[1].start == points[2].date)
        #expect(runs[1].end == points[3].date)
        #expect(runs.allSatisfy { $0.state == "charging" })
    }

    @Test func singletonStateRunsHaveEqualStartAndEnd() {
        let points = [
            StatePoint(0, "charging"),
            StatePoint(60, "pluggedIn"),
            StatePoint(120, "charging")
        ]
        let runs = ChartSegmentation.stateRuns(
            points, date: { $0.date }, state: { $0.state })
        // Singleton runs are kept, not filtered: callers widen them so a
        // single sample still draws.
        #expect(runs.count == 3)
        for (index, run) in runs.enumerated() {
            #expect(run.start == points[index].date)
            #expect(run.end == points[index].date)
            #expect(run.state == points[index].state)
        }
    }

    @Test func emptyInputYieldsNoStateRuns() {
        let runs = ChartSegmentation.stateRuns(
            [StatePoint](), date: { $0.date }, state: { $0.state })
        #expect(runs.isEmpty)
    }
}
