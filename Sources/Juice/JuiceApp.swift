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

    private static let menuBarConsumerID = UUID()

    @StateObject private var model: BatteryViewModel
    @ObservedObject private var live = LivePowerCoordinator.shared
    // Create the updater with the app so Sparkle can schedule opted-in checks
    // even while the menu bar popover is closed.
    private let updater = UpdateController.shared

    init() {
        let isMacMini = MacHardware.isCurrentMacMini
        _model = StateObject(wrappedValue: BatteryViewModel(
            onReading: JuiceApp.handleReading,
            isMacMini: isMacMini))

        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        StatusItemVisibilityGuard.engage()

        // A Mac mini has no battery event that can drive the status item.
        // Keep the lightweight live sampler attached so its wattage remains
        // current even while the popover is closed.
        if isMacMini {
            LivePowerCoordinator.shared.onReading = { reading in
                await Self.sampler?.recordServerReading(
                    reading,
                    at: reading.sampledAt ?? Date())
            }
            LivePowerCoordinator.shared.setAttached(
                true,
                includesTodayHistory: false,
                for: .menuBar(Self.menuBarConsumerID))
        }

        #if DEV_HELPER
        // Deterministic native-window entry point for development UI
        // verification. It is absent from production builds and does nothing
        // unless explicitly requested on the command line.
        if isMacMini, CommandLine.arguments.contains("--show-server-stats") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                StatsWindowPresenter.shared.showServer(store: Self.sampler?.store)
            }
        }
        if isMacMini, CommandLine.arguments.contains("--show-popover") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                StatusItemVisibilityGuard.showPopoverForTesting()
            }
        }
        #endif

        Task {
            // DEV_HELPER pairs with the explicitly installed legacy launchd
            // daemon. Do not let SMAppService reconcile the same development
            // label or it will unregister that daemon out from under the app.
            #if !DEV_HELPER
            await HelperRegistrationController.shared.prepare()
            #endif
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
            if model.isMacMini {
                if let watts = live.reading?.totalMeteredWatts {
                    Text(liveWattsText(watts))
                } else {
                    Image(systemName: "bolt")
                }
            } else {
                // Icon only, like the system battery item; recomputed from the
                // observed model so it tracks battery and Low Power Mode changes.
                Image(nsImage: BatteryStatusIcon.image(
                    for: model.reading,
                    isLowPowerModeEnabled: model.isLowPowerModeEnabled))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
