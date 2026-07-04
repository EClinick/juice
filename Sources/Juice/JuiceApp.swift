import SwiftUI

@main
struct JuiceApp: App {
    @StateObject private var model = BatteryViewModel()

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
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
