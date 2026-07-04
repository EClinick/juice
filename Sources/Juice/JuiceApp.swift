import SwiftUI

@main
struct JuiceApp: App {
    @StateObject private var model = BatteryViewModel()

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "battery.75percent")
                Text(model.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
