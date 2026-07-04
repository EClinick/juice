import SwiftUI
import Charts
import JuiceCore

/// A larger charge-timeline chart for the standalone Stats window.
///
/// Mirrors ``ChargeTimelineView`` but sizes up for a full window. A little
/// duplication keeps the popover's compact chart independent of this one;
/// both build their segments and AC runs from ``ChartSegmentation``.
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
            ForEach(segments.indices, id: \.self) { index in
                ForEach(segments[index]) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        y: .value("Charge", sample.percent),
                        series: .value("Segment", index)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(.linearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Charge", sample.percent),
                        series: .value("Segment", index)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // Highlight stretches spent on AC power.
            ForEach(acPeriods, id: \.start) { period in
                RectangleMark(
                    xStart: .value("Start", period.start),
                    xEnd: .value("End", period.end),
                    yStart: .value("Min", 0),
                    yEnd: .value("Max", 100)
                )
                .foregroundStyle(Color.green.opacity(0.12))
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
            if let since = recordingSince {
                Text("Recording since \(since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    /// Contiguous runs of samples, split wherever recording gapped out.
    private var segments: [[BatterySample]] {
        ChartSegmentation.segments(samples, date: { $0.date })
    }

    /// Stretches on AC power, never bridging a recording gap, clipped to the
    /// chart's pinned window.
    private var acPeriods: [(start: Date, end: Date)] {
        ChartSegmentation.acRuns(samples, date: { $0.date }, onAC: { $0.onAC })
            .compactMap { run in
                let start = max(run.start, windowStart)
                let end = min(run.end, windowEnd)
                guard start < end else { return nil }
                return (start: start, end: end)
            }
    }

    /// When history starts noticeably after the window opens, the first
    /// sample's date - shown so the empty leading region is explained.
    private var recordingSince: Date? {
        guard let first = samples.first,
              first.date.timeIntervalSince(windowStart) > 120
        else { return nil }
        return first.date
    }
}
