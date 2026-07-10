import SwiftUI
import JuiceCore

struct PopoverView: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject private var updater = UpdateController.shared

    private let selector = EnergySourceSelector()

    @State private var range: EnergyRange = .today
    @State private var topApps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []
    @State private var timelineWindowEnd = Date()
    @State private var origin: DataOrigin = .sample
    @State private var insights: [Insight] = []
    @State private var coverageDayCount: Int?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = model.reading, r.hasBattery {
                HStack {
                    Text("Battery - \(r.percent)%")
                        .font(.headline)
                    Spacer()
                    Text(model.timeRemainingText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if r.onAC {
                        Label(r.isCharging ? String(format: "Charging at %.1f W", abs(r.watts))
                                           : "Plugged in, not charging",
                              systemImage: "powerplug")
                    } else {
                        Label(String(format: "Drawing %.1f W", abs(r.watts)),
                              systemImage: "bolt")
                    }
                    Spacer()
                }
                .font(.callout)

                Divider()

                HStack {
                    if let health = r.healthPercent {
                        Text("Health \(health)%")
                        Text("·")
                    }
                    Text("\(r.cycleCount) cycles")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Top energy users")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if origin == .sample {
                        Text("Sample data - helper not connected")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                TopAppsView(apps: topApps, range: $range)
                if origin == .live, range != .today {
                    Text("Live data only (about 3 days) - history store unavailable")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if origin == .store, let days = coverageDayCount {
                    Text("History covers \(days) day\(days == 1 ? "" : "s") so far")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                Text("Battery level - last 24 h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimelineLegend()
                if timeline.isEmpty {
                    Text("Collecting charge history - check back in a few minutes.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ChargeTimelineView(
                        samples: timeline,
                        windowStart: timelineWindowEnd.addingTimeInterval(-24 * 3600),
                        windowEnd: timelineWindowEnd
                    )
                }

                if !insights.isEmpty {
                    Divider()
                    ForEach(insights.prefix(2)) { insight in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: iconName(for: insight.severity))
                                .foregroundStyle(color(for: insight.severity))
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(insight.title).font(.caption.weight(.medium))
                                Text(insight.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("No battery detected.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            if updater.isAvailable {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Toggle("Automatic updates", isOn: Binding(
                            get: { updater.automaticallyUpdates },
                            set: { updater.automaticallyUpdates = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                    }
                    Text("Turn this off to update manually.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
            }

            HStack {
                Button("Refresh") { model.refresh() }
                Button("Stats") {
                    StatsWindowPresenter.shared.show(
                        selector: selector,
                        timelineSource: timelineSource,
                        reading: model.reading
                    )
                }
                Spacer()
                Button("Quit Juice") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
        .task { await loadEnergy() }
        .onChange(of: range) {
            loadTask?.cancel()
            loadTask = Task { await loadTopApps() }
        }
    }

    private var timelineSource: EnergySource {
        if let store = JuiceApp.sampler?.store {
            return StoreEnergySource(store: store)
        }
        return selector.fallbackSource
    }

    private func loadEnergy() async {
        await loadTopApps()
        // Charge history comes from the local sample store. One captured
        // window end anchors both the store query and the chart's x-domain.
        if let store = JuiceApp.sampler?.store {
            let windowEnd = Date()
            if let timeline = try? await StoreEnergySource(store: store)
                .batteryTimeline(hours: 24, until: windowEnd) {
                self.timeline = timeline
                self.timelineWindowEnd = windowEnd
            }
            insights = await InsightsProvider(store: store).currentInsights()
        }
    }

    private func iconName(for severity: InsightSeverity) -> String {
        switch severity {
        case .warning: return "exclamationmark.triangle"
        case .notice: return "lightbulb"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: InsightSeverity) -> Color {
        switch severity {
        case .warning: return .orange
        case .notice: return .yellow
        case .info: return .blue
        }
    }

    private func loadTopApps() async {
        // Capture the requested range: if the selection changes while the
        // query is in flight, the stale result must not overwrite the newer
        // selection's data.
        let range = self.range
        let result = await selector.topApps(range: range)
        guard !Task.isCancelled, range == self.range else { return }
        topApps = result.apps
        origin = result.origin
        coverageDayCount = result.coverageDayCount
    }
}
