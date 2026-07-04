import SwiftUI
import AppKit

/// The standalone Stats window content: a full per-app energy table alongside a
/// 7-day charge timeline, with a battery-health footer.
struct StatsView: View {
    let energySource: EnergySource
    let timelineSource: EnergySource
    let reading: BatteryReading?

    /// The charge timeline always covers the last 7 days.
    private static let timelineHours = 24 * 7

    @State private var range: EnergyRange = .today
    @State private var apps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []
    @State private var refreshedAt = Date()

    private var totalEnergy: Double {
        max(apps.reduce(0) { $0 + $1.energyWh }, 0.001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                appTable
                    .frame(minWidth: 260)
                Divider()
                timelinePane
                    .frame(minWidth: 260)
            }

            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await load() }
        .onChange(of: range) {
            Task { await loadApps() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Juice Stats")
                        .font(.title2.weight(.semibold))
                    Text(rangeSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Range", selection: $range) {
                ForEach(EnergyRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
        .padding(16)
    }

    private var rangeSubtitle: String {
        switch range {
        case .today: return "Energy usage over the last day"
        case .threeDays: return "Energy usage over the last 3 days"
        case .week: return "Energy usage over the last week"
        }
    }

    // MARK: - App table

    private var appTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps by energy")
                .font(.caption)
                .foregroundStyle(.secondary)

            if apps.isEmpty {
                Text("No energy data available.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(apps) { app in
                            StatsAppRow(
                                app: app,
                                share: app.energyWh / totalEnergy
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // MARK: - Timeline pane

    private var timelinePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Charge — last 7 days")
                .font(.caption)
                .foregroundStyle(.secondary)

            if timeline.isEmpty {
                Text("Charge history arrives with the local sample store.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                StatsTimelineChart(samples: timeline, hours: Self.timelineHours)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let health = reading?.healthPercent {
                Text("Health \(health)%")
                Text("·")
            }
            if let cycles = reading?.cycleCount {
                Text("\(cycles) cycles")
                Text("·")
            }
            Text("Data from macOS powerlog · refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
    }

    // MARK: - Loading

    private func load() async {
        await loadApps()
        if let timeline = try? await timelineSource.batteryTimeline(hours: Self.timelineHours) {
            self.timeline = timeline
        }
        refreshedAt = Date()
    }

    private func loadApps() async {
        if let apps = try? await energySource.topApps(range: range) {
            self.apps = apps.sorted { $0.energyWh > $1.energyWh }
        }
    }
}

/// One row in the full app-energy table: icon, name, Wh, CPU hours, and a
/// share-of-total bar.
private struct StatsAppRow: View {
    let app: AppEnergy
    let share: Double

    var body: some View {
        HStack(spacing: 10) {
            StatsAppIconView(bundleId: app.bundleId, displayName: app.displayName)
                .frame(width: 20, height: 20)

            Text(app.displayName)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, share))))
                }
            }
            .frame(width: 60, height: 5)

            Text(String(format: "%.1f Wh", app.energyWh))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)

            Text(String(format: "%.1f h CPU", app.cpuHours))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }
}

/// The app's real icon when the bundle id resolves, otherwise a lettered
/// placeholder. Mirrors the icon-loading approach in ``TopAppsView``.
private struct StatsAppIconView: View {
    let bundleId: String
    let displayName: String

    var body: some View {
        if let icon = Self.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.25))
                .overlay(
                    Text(String(displayName.prefix(1)))
                        .font(.system(size: 11, weight: .semibold))
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
