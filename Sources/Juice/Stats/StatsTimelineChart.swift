import SwiftUI
import Charts
import JuiceCore

enum StatsTimelineViewport: Int, CaseIterable, Identifiable {
    case day = 24
    case threeDays = 72
    case week = 168
    case all = 2_160

    var id: Int { rawValue }
    var duration: TimeInterval { Double(rawValue) * 3600 }

    var label: String {
        switch self {
        case .day: return "1D"
        case .threeDays: return "3D"
        case .week: return "7D"
        case .all: return "All"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .day: return "1 day"
        case .threeDays: return "3 days"
        case .week: return "7 days"
        case .all: return "All retained battery history"
        }
    }

    var navigationLabel: String {
        switch self {
        case .day: return "day"
        case .threeDays: return "3 days"
        case .week: return "7 days"
        case .all: return "retained battery history"
        }
    }
}

enum StatsTimelineAxisInterval: Equatable {
    case hour(Int)
    case day(Int)
    case week(Int)
    case month(Int)
}

enum StatsTimelineAxisLabelStyle: Equatable {
    case time
    case weekdayTime
    case weekdayDay
    case monthDay
}

struct StatsTimelineAxisPlan: Equatable {
    let interval: StatsTimelineAxisInterval
    let labelStyle: StatsTimelineAxisLabelStyle
}

/// Pure timeline interaction math, kept separate from SwiftUI so selection and
/// viewport boundary behavior can be covered without synthesizing pointer input.
enum StatsTimelineInteraction {
    /// A normal one-minute sample owns at most one minute on either side. This
    /// leaves the middle of recording gaps inspectable as "No data" rather than
    /// snapping the cursor to a distant, potentially misleading reading.
    static let sampleSelectionRadius: TimeInterval = 60

    static func axisPlan(
        for viewport: StatsTimelineViewport,
        plotWidth: Double
    ) -> StatsTimelineAxisPlan {
        let narrow = plotWidth < 360
        switch viewport {
        case .day:
            return StatsTimelineAxisPlan(
                interval: .hour(6),
                labelStyle: .time)
        case .threeDays:
            return StatsTimelineAxisPlan(
                interval: narrow ? .day(1) : .hour(12),
                labelStyle: narrow ? .weekdayDay : .weekdayTime)
        case .week:
            return StatsTimelineAxisPlan(
                interval: .day(narrow ? 2 : 1),
                labelStyle: .weekdayDay)
        case .all:
            return StatsTimelineAxisPlan(
                interval: narrow ? .month(1) : .week(2),
                labelStyle: .monthDay)
        }
    }

    static func axisTickDates(
        plan: StatsTimelineAxisPlan,
        visibleStart: Date,
        visibleEnd: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard visibleStart < visibleEnd else { return [] }

        let component: Calendar.Component
        let count: Int
        let anchor: Date?
        switch plan.interval {
        case let .hour(value):
            component = .hour
            count = value
            anchor = calendar.startOfDay(for: visibleStart)
        case let .day(value):
            component = .day
            count = value
            anchor = calendar.startOfDay(for: visibleStart)
        case let .week(value):
            component = .weekOfYear
            count = value
            anchor = calendar.dateInterval(of: .weekOfYear, for: visibleStart)?.start
        case let .month(value):
            component = .month
            count = value
            anchor = calendar.dateInterval(of: .month, for: visibleStart)?.start
        }
        guard count > 0, var tick = anchor else { return [] }
        while tick < visibleStart {
            guard let next = calendar.date(byAdding: component, value: count, to: tick),
                  next > tick
            else { return [] }
            tick = next
        }

        var ticks: [Date] = []
        while tick <= visibleEnd {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: component, value: count, to: tick),
                  next > tick
            else { break }
            tick = next
        }
        return ticks
    }

    /// Removes ticks too close to a visible edge to fit their short date label.
    /// The cap keeps useful boundary-adjacent ticks on very long ranges.
    static func insetAxisTicks(
        _ ticks: [Date],
        visibleStart: Date,
        visibleEnd: Date,
        plotWidth: Double
    ) -> [Date] {
        guard plotWidth > 0, visibleStart < visibleEnd else { return ticks }
        let edgeFraction = min(0.08, 24 / plotWidth)
        let inset = visibleEnd.timeIntervalSince(visibleStart) * edgeFraction
        return ticks.filter {
            $0.timeIntervalSince(visibleStart) >= inset
                && visibleEnd.timeIntervalSince($0) >= inset
        }
    }

    static func sampleIndex(
        nearest date: Date,
        in samples: [BatterySample],
        maximumDistance: TimeInterval = sampleSelectionRadius
    ) -> Int? {
        guard !samples.isEmpty else { return nil }

        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var bestIndex: Int?
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        for candidate in [lower - 1, lower] where samples.indices.contains(candidate) {
            let distance = abs(samples[candidate].date.timeIntervalSince(date))
            if distance < bestDistance {
                bestIndex = candidate
                bestDistance = distance
            }
        }
        return bestDistance <= maximumDistance ? bestIndex : nil
    }

    static func latestScrollStart(
        windowStart: Date,
        windowEnd: Date,
        visibleDuration: TimeInterval
    ) -> Date {
        max(windowStart, windowEnd.addingTimeInterval(-visibleDuration))
    }

    static func clampedScrollStart(
        _ proposed: Date,
        windowStart: Date,
        windowEnd: Date,
        visibleDuration: TimeInterval
    ) -> Date {
        min(
            max(proposed, windowStart),
            latestScrollStart(
                windowStart: windowStart,
                windowEnd: windowEnd,
                visibleDuration: visibleDuration))
    }

    static func shiftedScrollStart(
        _ current: Date,
        pages: Int,
        windowStart: Date,
        windowEnd: Date,
        visibleDuration: TimeInterval
    ) -> Date {
        clampedScrollStart(
            current.addingTimeInterval(Double(pages) * visibleDuration),
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration)
    }

    static func isAtLatest(
        _ scrollStart: Date,
        windowStart: Date,
        windowEnd: Date,
        visibleDuration: TimeInterval,
        tolerance: TimeInterval = 1
    ) -> Bool {
        abs(scrollStart.timeIntervalSince(latestScrollStart(
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration))) <= tolerance
    }

    /// Reduces each contiguous segment independently, retaining endpoints and
    /// time-bucket extrema whenever the point budget allows. If fragmented
    /// history has more essential endpoints than the budget can hold, a
    /// deterministic subset is retained as singleton segments. Gaps can
    /// therefore never be bridged and the target remains a hard upper bound.
    static func reducedSegments(
        _ samples: [BatterySample],
        targetPointCount: Int
    ) -> [[BatterySample]] {
        let segments = ChartSegmentation.segments(samples, date: { $0.date })
        guard targetPointCount > 0 else { return [] }
        guard samples.count > targetPointCount else {
            return segments
        }

        let minimumBudgets = segments.map { min($0.count, $0.count == 1 ? 1 : 2) }
        let requiredPoints = minimumBudgets.reduce(0, +)
        guard requiredPoints <= targetPointCount else {
            return reduceFragmentedSegments(
                segments,
                maximumPointCount: targetPointCount)
        }
        let distributable = max(0, targetPointCount - requiredPoints)
        let optionalPoints = zip(segments, minimumBudgets)
            .reduce(0) { $0 + max(0, $1.0.count - $1.1) }

        return zip(segments, minimumBudgets).map { segment, minimumBudget in
            let proportional = optionalPoints == 0 ? 0 : Int(
                (Double(distributable) * Double(segment.count - minimumBudget)
                    / Double(optionalPoints)).rounded(.down))
            return reduceSegment(
                segment,
                maximumPointCount: min(segment.count, minimumBudget + proportional))
        }
    }

    private static func reduceSegment(
        _ segment: [BatterySample],
        maximumPointCount: Int
    ) -> [BatterySample] {
        guard maximumPointCount > 0 else { return [] }
        guard segment.count > maximumPointCount,
              let first = segment.first, let last = segment.last
        else { return segment }
        if maximumPointCount == 1 { return [first] }
        if maximumPointCount == 2 { return [first, last] }
        if maximumPointCount == 3 {
            let interior = segment.indices.dropFirst().dropLast().max { left, right in
                deviation(at: left, in: segment) < deviation(at: right, in: segment)
            }
            return interior.map { [first, segment[$0], last] } ?? [first, last]
        }

        let interiorCount = segment.count - 2
        let bucketCount = max(1, (maximumPointCount - 2) / 2)
        var result: [BatterySample] = [first]
        result.reserveCapacity(maximumPointCount)

        for bucket in 0..<bucketCount {
            let lower = 1 + interiorCount * bucket / bucketCount
            let upper = 1 + interiorCount * (bucket + 1) / bucketCount
            guard lower < upper else { continue }

            var minimumIndex = lower
            var maximumIndex = lower
            for index in (lower + 1)..<upper {
                if segment[index].percent < segment[minimumIndex].percent {
                    minimumIndex = index
                }
                if segment[index].percent > segment[maximumIndex].percent {
                    maximumIndex = index
                }
            }
            for index in [minimumIndex, maximumIndex].sorted() where result.last?.date != segment[index].date {
                result.append(segment[index])
            }
        }
        if result.last?.date != last.date { result.append(last) }
        return result
    }

    private static func deviation(at index: Int, in segment: [BatterySample]) -> Double {
        let progress = Double(index) / Double(segment.count - 1)
        let expected = Double(segment[0].percent)
            + Double(segment[segment.count - 1].percent - segment[0].percent) * progress
        return abs(Double(segment[index].percent) - expected)
    }

    private struct IndexedSample {
        struct Key: Hashable {
            let segment: Int
            let sample: Int
        }

        let key: Key
        let value: BatterySample
    }

    /// Handles the mathematically constrained case where retaining both ends
    /// of every segment would itself exceed the point budget. Selected points
    /// are returned as singletons, so omitting a segment cannot create a line
    /// across its recording gap.
    private static func reduceFragmentedSegments(
        _ segments: [[BatterySample]],
        maximumPointCount: Int
    ) -> [[BatterySample]] {
        guard maximumPointCount > 0 else { return [] }
        let all = segments.enumerated().flatMap { segmentIndex, segment in
            segment.enumerated().map { sampleIndex, sample in
                IndexedSample(
                    key: .init(segment: segmentIndex, sample: sampleIndex),
                    value: sample)
            }
        }
        guard !all.isEmpty else { return [] }

        let minimum = all.min {
            ($0.value.percent, $0.value.date) < ($1.value.percent, $1.value.date)
        }
        let maximum = all.max {
            ($0.value.percent, $0.value.date) < ($1.value.percent, $1.value.date)
        }
        var selected: [IndexedSample] = []
        var selectedKeys = Set<IndexedSample.Key>()
        func select(_ candidate: IndexedSample?) {
            guard selected.count < maximumPointCount,
                  let candidate,
                  selectedKeys.insert(candidate.key).inserted
            else { return }
            selected.append(candidate)
        }

        select(all.first)
        select(all.last)
        select(minimum)
        select(maximum)

        let remaining = all.filter { !selectedKeys.contains($0.key) }
        let remainingSlots = min(maximumPointCount - selected.count, remaining.count)
        if remainingSlots == 1 {
            select(remaining[remaining.count / 2])
        } else if remainingSlots > 1 {
            for slot in 0..<remainingSlots {
                select(remaining[slot * (remaining.count - 1) / (remainingSlots - 1)])
            }
        }

        return selected
            .sorted {
                ($0.key.segment, $0.key.sample) < ($1.key.segment, $1.key.sample)
            }
            .map { [$0.value] }
    }

    /// Snaps sample inspection to the actual sample date so pointer motion
    /// within the same reading produces no state update. No-data inspection is
    /// quantized to one second to suppress pointer-frequency duplicates without
    /// visibly moving the rule away from the pointer.
    static func inspectionSelection(
        nearest date: Date,
        in samples: [BatterySample]
    ) -> StatsTimelineInspectionSelection {
        if let index = sampleIndex(nearest: date, in: samples) {
            return StatsTimelineInspectionSelection(date: samples[index].date, sampleIndex: index)
        }
        let interval: TimeInterval = 1
        let quantized = (date.timeIntervalSinceReferenceDate / interval).rounded() * interval
        return StatsTimelineInspectionSelection(
            date: Date(timeIntervalSinceReferenceDate: quantized),
            sampleIndex: nil)
    }
}

struct StatsTimelineInspectionSelection: Equatable {
    let date: Date
    let sampleIndex: Int?
}

/// Pure refresh policy for the retained timeline. The first load covers the
/// full retention horizon; later loads overlap the previous boundary so a
/// fresh or corrected sample replaces its cached counterpart.
enum StatsTimelineRefresh {
    static let overlap: TimeInterval = 120
    static let backfillReconciliationHours = 7 * 24

    static func requestHours(
        previousWindowEnd: Date?,
        windowEnd: Date,
        retentionHours: Int,
        historyRevisionChanged: Bool = false
    ) -> Int {
        guard retentionHours > 0 else { return 0 }
        guard let previousWindowEnd else { return retentionHours }
        let elapsed = windowEnd.timeIntervalSince(previousWindowEnd)
        guard elapsed > 0 else { return retentionHours }
        let incrementalHours = min(
            retentionHours,
            max(1, Int(ceil((elapsed + overlap) / 3600))))
        guard historyRevisionChanged else { return incrementalHours }
        return min(
            retentionHours,
            max(incrementalHours, backfillReconciliationHours))
    }

    /// Merges two chronologically ordered windows, preferring refreshed rows
    /// with identical timestamps and trimming everything outside retention.
    static func mergedSamples(
        existing: [BatterySample],
        refreshed: [BatterySample],
        retentionStart: Date
    ) -> [BatterySample] {
        var existingIndex = existing.partitioningIndex {
            $0.date >= retentionStart
        }
        var refreshedIndex = refreshed.partitioningIndex {
            $0.date >= retentionStart
        }
        var result: [BatterySample] = []
        result.reserveCapacity(
            existing.count - existingIndex + refreshed.count - refreshedIndex)

        func appendReplacingDuplicate(_ sample: BatterySample) {
            if result.last?.date == sample.date {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }

        while existingIndex < existing.count || refreshedIndex < refreshed.count {
            if refreshedIndex >= refreshed.count {
                appendReplacingDuplicate(existing[existingIndex])
                existingIndex += 1
            } else if existingIndex >= existing.count {
                appendReplacingDuplicate(refreshed[refreshedIndex])
                refreshedIndex += 1
            } else if existing[existingIndex].date < refreshed[refreshedIndex].date {
                appendReplacingDuplicate(existing[existingIndex])
                existingIndex += 1
            } else {
                // Refreshed values win both exact cross-window collisions and
                // duplicates within the refreshed overlap.
                let refreshedDate = refreshed[refreshedIndex].date
                appendReplacingDuplicate(refreshed[refreshedIndex])
                if existing[existingIndex].date == refreshedDate {
                    repeat { existingIndex += 1 }
                    while existingIndex < existing.count
                        && existing[existingIndex].date == refreshedDate
                }
                refreshedIndex += 1
            }
        }
        return result
    }
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

struct StatsTimelinePreparedData: Sendable {
    struct Region: Sendable {
        let start: Date
        let end: Date
    }

    struct Band: Sendable {
        let start: Date
        let end: Date
        let state: PowerBandState
    }

    static let minimumTargetPointCount = 1_200
    static let maximumTargetPointCount = 6_000
    static let targetPointsPerDay = 80

    static func targetPointCount(for duration: TimeInterval) -> Int {
        let days = max(0, duration / (24 * 3600))
        let scaled = Int(ceil(days * Double(targetPointsPerDay)))
        return min(
            maximumTargetPointCount,
            max(minimumTargetPointCount, scaled))
    }

    let samples: [BatterySample]
    let renderSegments: [[BatterySample]]
    let noDataRegions: [Region]
    let powerBands: [Band]
    let collectionBegan: Date?
    let renderTargetPointCount: Int

    var renderedPointCount: Int {
        renderSegments.reduce(0) { $0 + $1.count }
    }

    init(samples: [BatterySample], windowStart: Date, windowEnd: Date) {
        self.samples = samples
        renderTargetPointCount = Self.targetPointCount(
            for: windowEnd.timeIntervalSince(windowStart))
        renderSegments = StatsTimelineInteraction.reducedSegments(
            samples,
            targetPointCount: renderTargetPointCount)

        let fullSegments = ChartSegmentation.segments(samples, date: { $0.date })
        if let firstDate = fullSegments.first?.first?.date,
           let lastDate = fullSegments.last?.last?.date {
            var regions: [Region] = []
            if firstDate.timeIntervalSince(windowStart) > 120 {
                regions.append(Region(start: windowStart, end: firstDate))
            }
            if fullSegments.count > 1 {
                for index in 0..<(fullSegments.count - 1) {
                    if let gapStart = fullSegments[index].last?.date,
                       let gapEnd = fullSegments[index + 1].first?.date {
                        regions.append(Region(start: gapStart, end: gapEnd))
                    }
                }
            }
            if windowEnd.timeIntervalSince(lastDate) > 120 {
                regions.append(Region(start: lastDate, end: windowEnd))
            }
            noDataRegions = regions
            collectionBegan = firstDate.timeIntervalSince(windowStart) > 120 ? firstDate : nil
        } else {
            noDataRegions = [Region(start: windowStart, end: windowEnd)]
            collectionBegan = nil
        }

        powerBands = ChartSegmentation.stateRuns(
            samples, date: { $0.date }, state: { PowerBandState(sample: $0) })
            .compactMap { run in
                guard run.state.bandColor != nil else { return nil }
                var start = run.start
                var end = run.end
                if start == end {
                    start = start.addingTimeInterval(-30)
                    end = end.addingTimeInterval(30)
                }
                start = max(start, windowStart)
                end = min(end, windowEnd)
                guard start < end else { return nil }
                return Band(start: start, end: end, state: run.state)
            }
    }
}

/// A larger battery-level chart for the standalone Stats window.
///
/// Mirrors ``ChargeTimelineView`` but sizes up for a full window. A little
/// duplication keeps the popover's compact chart independent of this one;
/// both build their segments and power-state runs from ``ChartSegmentation``.
///
/// The x-axis is pinned to the window `[windowEnd - hours, windowEnd]` rather
/// than the data extent, so partial history never stretches to fill the chart.
struct StatsTimelineChart: View {
    let preparedData: StatsTimelinePreparedData
    let hours: Int
    let windowEnd: Date

    @State private var viewport: StatsTimelineViewport = .week
    @State private var scrollStart: Date
    @State private var followsLatest = true
    @State private var inspectionGeneration = 0

    init(preparedData: StatsTimelinePreparedData, hours: Int, windowEnd: Date) {
        self.preparedData = preparedData
        self.hours = hours
        self.windowEnd = windowEnd
        let start = windowEnd.addingTimeInterval(-Double(hours) * 3600)
        _scrollStart = State(initialValue: StatsTimelineInteraction.latestScrollStart(
            windowStart: start,
            windowEnd: windowEnd,
            visibleDuration: min(
                StatsTimelineViewport.week.duration,
                Double(hours) * 3600)))
    }

    private var windowStart: Date {
        windowEnd.addingTimeInterval(-Double(hours) * 3600)
    }

    private var totalDuration: TimeInterval {
        Double(hours) * 3600
    }

    private var visibleDuration: TimeInterval {
        min(viewport.duration, totalDuration)
    }

    private var latestScrollStart: Date {
        StatsTimelineInteraction.latestScrollStart(
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration)
    }

    private var isAtLatest: Bool {
        StatsTimelineInteraction.isAtLatest(
            scrollStart,
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration)
    }

    private var isAtBeginning: Bool {
        abs(scrollStart.timeIntervalSince(windowStart)) <= 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            viewportControls
            chart
        }
        .onChange(of: viewport) {
            inspectionGeneration &+= 1
            scrollToLatest()
        }
        .onChange(of: scrollStart) {
            followsLatest = isAtLatest
        }
        .onChange(of: windowEnd) {
            inspectionGeneration &+= 1
            if followsLatest {
                scrollStart = latestScrollStart
            } else {
                scrollStart = StatsTimelineInteraction.clampedScrollStart(
                    scrollStart,
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    visibleDuration: visibleDuration)
            }
        }
    }

    private var viewportControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Picker("Visible time window", selection: $viewport) {
                    ForEach(StatsTimelineViewport.allCases) { candidate in
                        Text(candidate.label)
                            .accessibilityLabel(candidate.accessibilityLabel)
                            .tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 144)
                .help("Choose a recent window or all retained battery history (up to 90 days)")

                Button {
                    moveViewport(pages: -1)
                } label: {
                    Label("Earlier", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isAtBeginning)
                .help(earlierHelp)

                Button {
                    moveViewport(pages: 1)
                } label: {
                    Label("Later", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isAtLatest)
                .help(laterHelp)

                Button {
                    scrollToLatest()
                } label: {
                    Label("Latest", systemImage: "arrow.right.to.line")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isAtLatest)
                .help("Return to the latest battery readings")
            }

            Text(visibleWindowLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var chart: some View {
        GeometryReader { geometry in
            timelineChart(plotWidth: max(1, geometry.size.width - 46))
        }
    }

    private var earlierHelp: String {
        if viewport == .all {
            return "All retained battery history is already visible"
        }
        return "Show the previous \(viewport.navigationLabel) of battery history"
    }

    private var laterHelp: String {
        if viewport == .all {
            return "All retained battery history is already visible"
        }
        return "Show the next \(viewport.navigationLabel) of battery history"
    }

    private func timelineChart(plotWidth: CGFloat) -> some View {
        let axisPlan = StatsTimelineInteraction.axisPlan(
            for: viewport,
            plotWidth: Double(plotWidth))
        let axisStart = StatsTimelineInteraction.clampedScrollStart(
            scrollStart,
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration)
        let axisEnd = min(axisStart.addingTimeInterval(visibleDuration), windowEnd)
        let axisTicks = StatsTimelineInteraction.insetAxisTicks(
            StatsTimelineInteraction.axisTickDates(
                plan: axisPlan,
                visibleStart: axisStart,
                visibleEnd: axisEnd),
            visibleStart: axisStart,
            visibleEnd: axisEnd,
            plotWidth: Double(plotWidth))

        return Chart {
            // No-data regions first, so everything else draws on top.
            ForEach(preparedData.noDataRegions, id: \.start) { region in
                RectangleMark(
                    xStart: .value("Start", region.start),
                    xEnd: .value("End", region.end),
                    yStart: .value("Min", 0),
                    yEnd: .value("Max", 100)
                )
                .foregroundStyle(Color.secondary.opacity(0.08))
            }

            ForEach(preparedData.renderSegments.indices, id: \.self) { index in
                if preparedData.renderSegments[index].count == 1,
                   let sample = preparedData.renderSegments[index].first {
                    // A one-sample segment draws no area or line; a point
                    // keeps it visible.
                    PointMark(
                        x: .value("Time", sample.date),
                        y: .value("Charge", sample.percent)
                    )
                    .foregroundStyle(Color.blue)
                    .symbolSize(20)
                } else {
                    ForEach(preparedData.renderSegments[index]) { sample in
                        AreaMark(
                            x: .value("Time", sample.date),
                            y: .value("Charge", sample.percent),
                            series: .value("Segment", index)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.linearGradient(
                            colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))

                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Charge", sample.percent),
                            series: .value("Segment", index)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
            }

            // Power-state band along the bottom: orange while charging, green
            // while plugged in but not charging.
            ForEach(preparedData.powerBands, id: \.start) { band in
                RectangleMark(
                    xStart: .value("Start", band.start),
                    xEnd: .value("End", band.end),
                    yStart: .value("Min", 0),
                    yEnd: .value("Max", 6)
                )
                .foregroundStyle(band.state.bandColor ?? .clear)
            }
        }
        .chartXScale(domain: windowStart...windowEnd)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDuration)
        .chartScrollPosition(x: $scrollStart)
        // Keep inspection hover-only so it never competes with horizontal
        // navigation gestures. Explicit Earlier/Later buttons provide the same
        // navigation to mouse and keyboard users regardless of scroll hardware.
        .chartOverlay { proxy in
            StatsTimelineInspectionOverlay(
                proxy: proxy,
                samples: preparedData.samples)
                .id(inspectionGeneration)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: axisTicks) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        axisLabel(for: date, style: axisPlan.labelStyle)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let since = preparedData.collectionBegan {
                Text("Data collection began \(since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .help("Hover to inspect a reading. Scroll horizontally to explore earlier history.")
    }

    private var visibleWindowLabel: String {
        let start = StatsTimelineInteraction.clampedScrollStart(
            scrollStart,
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration)
        let end = min(start.addingTimeInterval(visibleDuration), windowEnd)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) · \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    @ViewBuilder
    private func axisLabel(
        for date: Date,
        style: StatsTimelineAxisLabelStyle
    ) -> some View {
        Group {
            switch style {
            case .time:
                Text(date.formatted(date: .omitted, time: .shortened))
            case .weekdayTime:
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    Text(date.formatted(date: .omitted, time: .shortened))
                }
            case .weekdayDay:
                Text(date.formatted(.dateTime.weekday(.abbreviated).day()))
            case .monthDay:
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func scrollToLatest() {
        followsLatest = true
        scrollStart = latestScrollStart
    }

    private func moveViewport(pages: Int) {
        inspectionGeneration &+= 1
        followsLatest = false
        scrollStart = StatsTimelineInteraction.shiftedScrollStart(
            scrollStart,
            pages: pages,
            windowStart: windowStart,
            windowEnd: windowEnd,
            visibleDuration: visibleDuration)
    }
}

/// Owns rapidly changing pointer state outside the chart's mark builder. The
/// cached base chart therefore remains unchanged while the rule, point, and
/// callout move during hover or pinned inspection.
private struct StatsTimelineInspectionOverlay: View {
    let proxy: ChartProxy
    let samples: [BatterySample]

    @State private var hoverSelection: StatsTimelineInspectionSelection?
    @State private var pinnedSelection: StatsTimelineInspectionSelection?

    private var displayedSelection: StatsTimelineInspectionSelection? {
        hoverSelection ?? pinnedSelection
    }

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plotFrame = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .accessibilityLabel("Battery timeline")
                        .accessibilityHint("Hover to inspect a reading. Scroll horizontally to explore earlier history.")
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                updateHover(at: location, plotFrame: plotFrame)
                            case .ended:
                                if hoverSelection != nil { hoverSelection = nil }
                            }
                        }
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { event in
                                guard let selection = selection(
                                    at: event.location,
                                    plotFrame: plotFrame)
                                else { return }
                                if pinnedSelection != selection {
                                    pinnedSelection = selection
                                }
                            })

                    if let selection = displayedSelection,
                       let relativeX = proxy.position(forX: selection.date) {
                        let x = plotFrame.minX + relativeX
                        if plotFrame.minX...plotFrame.maxX ~= x {
                            selectionDecoration(
                                selection,
                                x: x,
                                plotFrame: plotFrame)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    private func updateHover(at location: CGPoint, plotFrame: CGRect) {
        let next = selection(at: location, plotFrame: plotFrame)
        if hoverSelection != next { hoverSelection = next }
    }

    private func selection(
        at location: CGPoint,
        plotFrame: CGRect
    ) -> StatsTimelineInspectionSelection? {
        guard plotFrame.contains(location),
              let date = proxy.value(
                atX: location.x - plotFrame.minX,
                as: Date.self)
        else { return nil }
        return StatsTimelineInteraction.inspectionSelection(
            nearest: date,
            in: samples)
    }

    @ViewBuilder
    private func selectionDecoration(
        _ selection: StatsTimelineInspectionSelection,
        x: CGFloat,
        plotFrame: CGRect
    ) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: plotFrame.minY))
            path.addLine(to: CGPoint(x: x, y: plotFrame.maxY))
        }
        .stroke(
            Color.primary.opacity(0.35),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        if let index = selection.sampleIndex,
           samples.indices.contains(index),
           let relativeY = proxy.position(forY: samples[index].percent) {
            Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
                .position(x: x, y: plotFrame.minY + relativeY)
        }

        inspectionAnnotation(selection)
            .fixedSize()
            .position(
                x: min(max(x, plotFrame.minX + 72), plotFrame.maxX - 72),
                y: plotFrame.minY + 34)
    }

    private func inspectionAnnotation(
        _ selection: StatsTimelineInspectionSelection
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let index = selection.sampleIndex, samples.indices.contains(index) {
                let sample = samples[index]
                Text("\(sample.percent)% · \(powerStateLabel(for: sample))")
                    .font(.caption.weight(.semibold))
                inspectionTimestamp(sample.date)
            } else {
                Text("No data")
                    .font(.caption.weight(.semibold))
                inspectionTimestamp(selection.date)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func powerStateLabel(for sample: BatterySample) -> String {
        if sample.isCharging { return "Charging" }
        if sample.onAC { return "Plugged in" }
        return "On battery"
    }

    private func inspectionTimestamp(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated).day()))
            Text(date.formatted(date: .omitted, time: .shortened))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
