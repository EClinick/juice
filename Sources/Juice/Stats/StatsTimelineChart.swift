import SwiftUI
import Charts
import JuiceCore

/// A larger battery-level chart for the standalone Stats window.
///
/// Mirrors ``ChargeTimelineView`` but sizes up for a full window. A little
/// duplication keeps the popover's compact chart independent of this one;
/// both build their segments and power-state runs from ``ChartSegmentation``.
///
/// The x-axis is pinned to the window `[windowEnd - hours, windowEnd]` rather
/// than the data extent, so partial history never stretches to fill the chart.
struct StatsTimelineChart: View {
    let samples: [BatterySample]
    let hours: Int
    let windowEnd: Date

    private var windowStart: Date {
        windowEnd.addingTimeInterval(-Double(hours) * 3600)
    }

    var body: some View {
        Chart {
            // No-data regions first, so everything else draws on top.
            ForEach(noDataRegions, id: \.start) { region in
                RectangleMark(
                    xStart: .value("Start", region.start),
                    xEnd: .value("End", region.end),
                    yStart: .value("Min", 0),
                    yEnd: .value("Max", 100)
                )
                .foregroundStyle(Color.secondary.opacity(0.08))
            }

            ForEach(segments.indices, id: \.self) { index in
                if segments[index].count == 1, let sample = segments[index].first {
                    // A one-sample segment draws no area or line; a point
                    // keeps it visible.
                    PointMark(
                        x: .value("Time", sample.date),
                        y: .value("Charge", sample.percent)
                    )
                    .foregroundStyle(Color.blue)
                    .symbolSize(20)
                } else {
                    ForEach(segments[index]) { sample in
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
            ForEach(powerBands, id: \.start) { band in
                RectangleMark(
                    xStart: .value("Start", band.start),
                    xEnd: .value("End", band.end),
                    yStart: .value("Min", 0),
                    yEnd: .value("Max", 6)
                )
                .foregroundStyle(band.color)
            }
        }
        .chartXScale(domain: windowStart...windowEnd)
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
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .overlay(alignment: .topLeading) {
            if let since = collectionBegan {
                Text("Data collection began \(since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    /// Contiguous runs of samples, split wherever recording gapped out.
    private var segments: [[BatterySample]] {
        ChartSegmentation.segments(samples, date: { $0.date })
    }

    /// Power-state runs to draw as bottom bands, clipped to the chart's
    /// pinned window. Singleton runs (start == end) are widened by 30 seconds
    /// on each side so a single sample still shows.
    private var powerBands: [(start: Date, end: Date, color: Color)] {
        ChartSegmentation.stateRuns(
            samples, date: { $0.date }, state: { PowerBandState(sample: $0) })
        .compactMap { run in
            guard let color = run.state.bandColor else { return nil }
            var start = run.start
            var end = run.end
            if start == end {
                start = start.addingTimeInterval(-30)
                end = end.addingTimeInterval(30)
            }
            start = max(start, windowStart)
            end = min(end, windowEnd)
            guard start < end else { return nil }
            return (start: start, end: end, color: color)
        }
    }

    /// Stretches of the window with no recorded samples: before the first
    /// sample, every internal gap larger than the segmentation threshold, and
    /// after the last sample.
    private var noDataRegions: [(start: Date, end: Date)] {
        let threshold: TimeInterval = 120
        let segs = segments
        guard let firstDate = segs.first?.first?.date,
              let lastDate = segs.last?.last?.date
        else { return [(start: windowStart, end: windowEnd)] }

        var regions: [(start: Date, end: Date)] = []
        if firstDate.timeIntervalSince(windowStart) > threshold {
            regions.append((start: windowStart, end: firstDate))
        }
        for index in 0..<(segs.count - 1) {
            if let gapStart = segs[index].last?.date,
               let gapEnd = segs[index + 1].first?.date {
                regions.append((start: gapStart, end: gapEnd))
            }
        }
        if windowEnd.timeIntervalSince(lastDate) > threshold {
            regions.append((start: lastDate, end: windowEnd))
        }
        return regions
    }

    /// When history starts noticeably after the window opens, the first
    /// sample's date - shown so the empty leading region is explained.
    private var collectionBegan: Date? {
        guard let first = samples.first,
              first.date.timeIntervalSince(windowStart) > 120
        else { return nil }
        return first.date
    }
}
