import SwiftUI
import AppKit

/// Opens and manages the standalone Stats window.
///
/// This is an accessory-policy (menu-bar) app, so showing a regular window
/// requires activating the app explicitly. A single window is reused across
/// invocations: repeated calls bring the existing window to the front rather
/// than opening duplicates.
final class StatsWindowPresenter {
    static let shared = StatsWindowPresenter()

    private var window: NSWindow?

    private init() {}

    func show(selector: EnergySourceSelector, timelineSource: EnergySource, reading: BatteryReading?) {
        NSApp.activate(ignoringOtherApps: true)

        let root = StatsView(
            selector: selector,
            timelineSource: timelineSource,
            reading: reading
        )

        if let window {
            // Refresh the content so the reopened window reflects current data.
            window.contentViewController = NSHostingController(rootView: root)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "Juice - Stats"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.setFrameAutosaveName("JuiceStatsWindow")
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.center()
    }
}
