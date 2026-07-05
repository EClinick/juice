import SwiftUI
import AppKit

/// The standalone Stats window content: a full per-app energy table alongside a
/// 7-day charge timeline, with a battery-health footer.
struct StatsView: View {
    let selector: EnergySourceSelector
    let timelineSource: EnergySource
    let reading: BatteryReading?

    /// The charge timeline always covers the last 7 days.
    private static let timelineHours = 24 * 7

    @State private var range: EnergyRange = .today
    @State private var apps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []
    @State private var timelineWindowEnd = Date()
    @State private var refreshedAt = Date()
    @State private var origin: DataOrigin = .sample
    @State private var coverageDayCount: Int?
    @State private var loadTask: Task<Void, Never>?

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
            loadTask?.cancel()
            loadTask = Task { await loadApps() }
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
                            ) {
                                AppDetailPresenter.shared.show(
                                    appKey: app.bundleId,
                                    displayName: app.displayName,
                                    range: range
                                )
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            }

            if origin == .sample {
                Text("Sample data - helper not connected")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if origin == .live, range != .today {
                Text("Live data only (about 3 days) - history store unavailable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if origin == .store, let days = coverageDayCount {
                Text("History covers \(days) day\(days == 1 ? "" : "s") so far")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // MARK: - Timeline pane

    private var timelinePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Charge - last 7 days")
                .font(.caption)
                .foregroundStyle(.secondary)

            if timeline.isEmpty {
                Text("Charge history arrives with the local sample store.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                StatsTimelineChart(
                    samples: timeline,
                    hours: Self.timelineHours,
                    windowEnd: timelineWindowEnd
                )
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
        // One captured window end anchors both the store query and the
        // chart's x-domain.
        let windowEnd = Date()
        if let timeline = try? await timelineSource.batteryTimeline(
            hours: Self.timelineHours, until: windowEnd) {
            self.timeline = timeline
            self.timelineWindowEnd = windowEnd
        }
        refreshedAt = Date()
    }

    private func loadApps() async {
        // Capture the requested range: if the picker changes while the query
        // is in flight, the stale result must not overwrite the newer
        // selection's data.
        let range = self.range
        let result = await selector.topApps(range: range)
        guard !Task.isCancelled, range == self.range else { return }
        apps = result.apps.sorted { $0.energyWh > $1.energyWh }
        origin = result.origin
        coverageDayCount = result.coverageDayCount
    }
}

/// One row in the full app-energy table: icon, name, Wh, CPU hours, and a
/// share-of-total bar. Tapping opens the per-app detail window; a chevron
/// appears on hover to hint at the interaction.
private struct StatsAppRow: View {
    let app: AppEnergy
    let share: Double
    let onTap: () -> Void

    @State private var hovering = false

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

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
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
