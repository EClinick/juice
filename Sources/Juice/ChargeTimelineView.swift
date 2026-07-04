import SwiftUI
import Charts

/// A compact chart of battery charge level over time, highlighting AC periods.
struct ChargeTimelineView: View {
    let samples: [BatterySample]

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("Charge", sample.percent)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(
                    colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                ))

                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Charge", sample.percent)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
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
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)")
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
        .frame(height: 70)
    }

    /// Contiguous stretches during which the battery was on AC power.
    private var acPeriods: [(start: Date, end: Date)] {
        var periods: [(start: Date, end: Date)] = []
        var runStart: Date?

        for sample in samples {
            if sample.onAC {
                if runStart == nil { runStart = sample.date }
            } else if let start = runStart {
                periods.append((start, sample.date))
                runStart = nil
            }
        }
        if let start = runStart, let last = samples.last {
            periods.append((start, last.date))
        }
        return periods
    }
}
