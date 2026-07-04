import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: BatteryViewModel

    private let energySource: EnergySource = MockEnergySource()

    @State private var range: EnergyRange = .today
    @State private var topApps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []

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

                Text("Top energy users")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TopAppsView(apps: topApps, range: $range)

                Divider()

                Text("Charge — last 24 h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ChargeTimelineView(samples: timeline)
            } else if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("No battery detected.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Refresh") { model.refresh() }
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

    private func loadEnergy() async {
        await loadTopApps()
        if let timeline = try? await energySource.batteryTimeline(hours: 24) {
            self.timeline = timeline
        }
    }

    private func loadTopApps() async {
        if let apps = try? await energySource.topApps(range: range) {
            self.topApps = apps
        }
    }
}
