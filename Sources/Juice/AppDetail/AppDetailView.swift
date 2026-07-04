import SwiftUI
import Charts
import AppKit
import JuiceCore

/// Detail window content for a single app: where its energy came from
/// (CPU/GPU/Neural Engine), when it was used across the range window, and a
/// plain-English explanation of the pattern.
///
/// Data arrives through an injected async `provider` closure so the view can
/// be previewed and tested without a live XPC connection.
struct AppDetailView: View {
    let displayName: String
    let bundleId: String
    let rangeLabel: String
    let windowStart: Date
    let windowEnd: Date
    let windowHours: Int
    let provider: () async throws -> AppEnergyBreakdown

    private enum LoadState {
        case loading
        case loaded(AppEnergyBreakdown)
        case failed
    }

    @State private var state: LoadState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .loading:
                ProgressView("Loading energy details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 6) {
                    Image(systemName: "bolt.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Detailed data needs the helper connection")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let breakdown):
                content(breakdown)
            }
        }
        .frame(minWidth: 460, minHeight: 380)
        .task {
            do {
                state = .loaded(try await provider())
            } catch {
                state = .failed
            }
        }
    }

    // MARK: - Loaded content

    private func content(_ breakdown: AppEnergyBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(breakdown)
            componentBreakdown(breakdown)
            hourlyChart(breakdown)
            explanation(breakdown)
            statLine(breakdown)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ breakdown: AppEnergyBreakdown) -> some View {
        HStack(spacing: 10) {
            DetailAppIconView(bundleId: bundleId, displayName: displayName)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(String(format: "%.1f Wh", breakdown.totalWh)) · \(rangeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Component breakdown

    private struct Component: Identifiable {
        var id: String { name }
        let name: String
        let wh: Double
        let share: Double
        let color: Color
    }

    private func components(_ breakdown: AppEnergyBreakdown) -> [Component] {
        [
            Component(name: "CPU", wh: breakdown.cpuWh,
                      share: breakdown.cpuShare, color: .accentColor),
            Component(name: "GPU", wh: breakdown.gpuWh,
                      share: breakdown.gpuShare, color: .orange),
            Component(name: "Neural Engine", wh: breakdown.aneWh,
                      share: breakdown.aneShare, color: .green)
        ]
    }

    private func componentBreakdown(_ breakdown: AppEnergyBreakdown) -> some View {
        let components = components(breakdown)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Where the energy went")
                .font(.caption)
                .foregroundStyle(.secondary)

            // One stacked horizontal bar; segments proportional to share.
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(components) { component in
                        Rectangle()
                            .fill(component.color)
                            .frame(width: geo.size.width
                                   * CGFloat(max(0, min(1, component.share))))
                    }
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(height: 8)

            HStack(spacing: 12) {
                ForEach(components) { component in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(component.color)
                            .frame(width: 7, height: 7)
                        Text(String(format: "%@ %.0f%% · %.1f Wh",
                                    component.name, component.share * 100, component.wh))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Hourly chart

    /// Hourly energy over the range window. The x-axis is pinned to the full
    /// window (matching ``ChargeTimelineView``) so hours with no energy show
    /// as gaps rather than the data stretching to fill the chart.
    private func hourlyChart(_ breakdown: AppEnergyBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Energy by hour")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart(breakdown.hourlyWh, id: \.bucketStart) { bucket in
                BarMark(
                    x: .value("Hour", bucket.bucketStart, unit: .hour),
                    y: .value("Energy", bucket.wh)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXScale(domain: windowStart...windowEnd)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let wh = value.as(Double.self) {
                            Text(String(format: "%.1f Wh", wh))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
                    AxisValueLabel()
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 90)
        }
    }

    // MARK: - Explanation and stats

    private func explanation(_ breakdown: AppEnergyBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why it used this much")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(
                BreakdownBuilder.explanation(for: breakdown, windowHours: windowHours),
                id: \.self
            ) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(line)
                }
                .font(.callout)
            }
        }
    }

    private func statLine(_ breakdown: AppEnergyBreakdown) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%.1f CPU-hours", breakdown.cpuHours))
            if breakdown.activeHours > 0 {
                Text("·")
                Text(String(format: "%.1f W average while active",
                            breakdown.totalWh / breakdown.activeHours))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// The app's real icon when the bundle id resolves, otherwise a lettered
/// placeholder. Mirrors the icon-loading approach in ``TopAppsView``.
private struct DetailAppIconView: View {
    let bundleId: String
    let displayName: String

    var body: some View {
        if let icon = Self.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.25))
                .overlay(
                    Text(String(displayName.prefix(1)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private static func icon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
