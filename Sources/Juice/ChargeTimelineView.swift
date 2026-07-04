import SwiftUI
import Charts
import JuiceCore

/// A compact chart of battery charge level over time, highlighting AC periods.
///
/// The x-axis is pinned to the requested window (`windowStart...windowEnd`)
/// rather than the data extent, so a few hours of samples never stretch to
/// fill a 24-hour chart. Samples are split into contiguous segments across
/// recording gaps so no line or area bridges a period with no data.
struct ChargeTimelineView: View {
    let samples: [BatterySample]
    let windowStart: Date
    let windowEnd: Date

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
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
            }
        }
        .overlay(alignment: .topLeading) {
            if let since = recordingSince {
                Text("Recording since \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .frame(height: 70)
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
