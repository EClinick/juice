import SwiftUI
import AppKit

/// Opens and manages the standalone Stats window.
///
/// This is an accessory-policy (menu-bar) app, so showing a regular window
/// requires activating the app explicitly. A single window is reused across
/// invocations: repeated calls bring the existing window to the front rather
/// than opening duplicates.
@MainActor
final class StatsWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = StatsWindowPresenter()

    private var window: NSWindow?

    private override init() { super.init() }

    /// The window is retained (`isReleasedWhenClosed = false`) and reused, so
    /// SwiftUI `.onDisappear` on the hosted StatsView cannot be trusted to fire
    /// on close. Detaching the whole Stats consumer family here guarantees the
    /// shared live loop stops when the window closes, whatever per-instance
    /// token the current view holds.
    func windowWillClose(_ notification: Notification) {
        LivePowerCoordinator.shared.detachAll(kind: .stats)
    }

    func show(selector: EnergySourceSelector, timelineSource: EnergySource?, reading: BatteryReading?) {
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
        let minimumContentSize = NSSize(
            width: StatsView.minimumContentWidth,
            height: StatsView.minimumContentHeight
        )
        window.contentMinSize = minimumContentSize
        window.setContentSize(NSSize(width: 760, height: 480))
        window.setFrameAutosaveName("JuiceStatsWindow")

        // Older versions allowed a 560-point-wide saved frame. Resize that
        // saved value once so opening Stats never hides the app-name column.
        let restoredContentSize = window.contentView?.bounds.size ?? .zero
        if restoredContentSize.width < minimumContentSize.width ||
            restoredContentSize.height < minimumContentSize.height {
            window.setContentSize(minimumContentSize)
        }
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.center()
    }
}
