import SwiftUI
import JuiceCore

@main
struct JuiceApp: App {
    /// Shared sampler backed by the local store; nil only if the store
    /// cannot be opened (e.g. Application Support is unwritable).
    static let sampler: SamplerService? = {
        do {
            return SamplerService(store: try JuiceStore.appDefault())
        } catch {
            NSLog("Juice: failed to open local store: \(error)")
            return nil
        }
    }()

    @StateObject private var model = BatteryViewModel(onReading: JuiceApp.handleReading)

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { await Self.sampler?.updateRollupsIfStale() }
    }

    /// Persists each reading and opportunistically refreshes the rollups;
    /// the 15-minute staleness check makes the frequent calls cheap.
    private static func handleReading(_ reading: BatteryReading) {
        guard let sampler else { return }
        // One sequential Task so the sample insert lands before the refresh
        // and the two never interleave.
        Task {
            await sampler.recordSample(reading)
            await sampler.updateRollupsIfStale()
        }
    }

    /// SF Symbol for the menu bar, derived from the current reading:
    /// nearest of battery.0/25/50/75/100percent, the bolt variant while charging,
    /// and battery.100percent when there is no reading yet.
    private var batteryIconName: String {
        guard let r = model.reading else { return "battery.100percent" }
        if r.isCharging { return "battery.100percent.bolt" }
        let bucket = (Double(r.percent) / 25.0).rounded() * 25
        return "battery.\(Int(bucket))percent"
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: batteryIconName)
                Text(model.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
