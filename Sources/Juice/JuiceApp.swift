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
    // Create the updater with the app so Sparkle can schedule opted-in checks
    // even while the menu bar popover is closed.
    private let updater = UpdateController.shared

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {
            await Self.sampler?.updateRollupsIfStale()
            await Self.sampler?.backfillIfNeeded()
        }
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

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // Icon only, like the system battery item; recomputed from the
            // observed model so it tracks every reading change.
            Image(nsImage: BatteryStatusIcon.image(for: model.reading))
        }
        .menuBarExtraStyle(.window)
    }
}
