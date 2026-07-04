import SwiftUI
import JuiceCore

struct PopoverView: View {
    @ObservedObject var model: BatteryViewModel

    private let liveSource: EnergySource = PowerlogEnergySource()
    private let fallbackSource: EnergySource = MockEnergySource()

    @State private var range: EnergyRange = .today
    @State private var topApps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []
    @State private var usingLiveData = false
    @State private var insights: [Insight] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = model.reading, r.hasBattery {
                HStack {
                    Text("Battery — \(r.percent)%")
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
                    if !usingLiveData {
                        Text("Sample data — helper not connected")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                TopAppsView(apps: topApps, range: $range)

                Divider()

                Text("Charge — last 24 h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if timeline.isEmpty {
                    Text("Collecting charge history - check back in a few minutes.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ChargeTimelineView(samples: timeline)
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

            HStack {
                Button("Refresh") { model.refresh() }
                Button("Stats") {
                    StatsWindowPresenter.shared.show(
                        energySource: usingLiveData ? liveSource : fallbackSource,
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
            Task { await loadTopApps() }
        }
    }

    private var timelineSource: EnergySource {
        if let store = JuiceApp.sampler?.store {
            return StoreEnergySource(store: store)
        }
        return fallbackSource
    }

    private func loadEnergy() async {
        await loadTopApps()
        // Charge history comes from the local sample store.
        if let store = JuiceApp.sampler?.store {
            if let timeline = try? await StoreEnergySource(store: store).batteryTimeline(hours: 24) {
                self.timeline = timeline
            }
            insights = InsightsProvider(store: store).currentInsights()
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
        if let apps = try? await liveSource.topApps(range: range), !apps.isEmpty {
            self.topApps = apps
            usingLiveData = true
        } else if let apps = try? await fallbackSource.topApps(range: range) {
            self.topApps = apps
            usingLiveData = false
        }
    }
}
