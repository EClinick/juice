import SwiftUI
import AppKit
import JuiceCore

/// Opens and manages the standalone Stats window.
///
/// This is an accessory-policy (menu-bar) app, so showing a regular window
/// requires activating the app explicitly. A single window is reused across
/// invocations: repeated calls bring the existing window to the front rather
/// than opening duplicates.
@MainActor
final class StatsWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = StatsWindowPresenter()

    private(set) var window: NSWindow?
    private let detachStatsConsumers: @MainActor () -> Void

    private override init() {
        detachStatsConsumers = {
            LivePowerCoordinator.shared.detachAll(kind: .stats)
            BatterySessionCoordinator.shared.detachAll(kind: .stats)
        }
        super.init()
    }

    /// Allows lifecycle behavior to be exercised without mutating the shared
    /// coordinators. Production uses ``shared``.
    init(detachStatsConsumers: @escaping @MainActor () -> Void) {
        self.detachStatsConsumers = detachStatsConsumers
        super.init()
    }

    /// The window is retained (`isReleasedWhenClosed = false`) and reused, so
    /// SwiftUI `.onDisappear` on the hosted StatsView cannot be trusted to fire
    /// on close. Detaching the whole Stats consumer family here guarantees the
    /// shared live loop stops when the window closes, whatever per-instance
    /// token the current view holds. Discarding the hosted view also cancels
    /// its minute refresh task; otherwise a closed, retained window would keep
    /// waking to query battery or server history indefinitely.
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }
        detachStatsConsumers()
        Self.discardHostedContent(from: closingWindow)
    }

    /// `present` always installs a fresh root before reopening the retained
    /// window, so keeping the hosting controller alive while the window is
    /// closed has no UX benefit and lets SwiftUI view tasks outlive their
    /// visibility. AppKit collapses a window's content geometry when its
    /// controller becomes nil, so use an inert placeholder to preserve frame
    /// autosave and retained-window reopen semantics.
    static func discardHostedContent(from window: NSWindow) {
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let placeholder = NSViewController()
        placeholder.preferredContentSize = contentSize
        placeholder.view = NSView(frame: NSRect(origin: .zero, size: contentSize))
        window.contentViewController = placeholder
        window.setContentSize(contentSize)
    }

    func show(selector: EnergySourceSelector, timelineSource: EnergySource?, model: BatteryViewModel) {
        NSApp.activate(ignoringOtherApps: true)

        let root = StatsView(
            selector: selector,
            timelineSource: timelineSource,
            model: model
        )
        present(
            root,
            title: "Juice - Stats",
            minimumContentSize: NSSize(
                width: StatsView.minimumContentWidth,
                height: StatsView.minimumContentHeight),
            contentSize: NSSize(width: 760, height: 480))
    }

    func showServer(store: JuiceStore?) {
        NSApp.activate(ignoringOtherApps: true)

        present(
            MacMiniStatsView(store: store),
            title: "Juice - Mac mini Stats",
            minimumContentSize: NSSize(
                width: MacMiniStatsView.minimumContentWidth,
                height: MacMiniStatsView.minimumContentHeight),
            contentSize: NSSize(width: 940, height: 600))
    }

    func present<Content: View>(
        _ root: Content,
        title: String,
        minimumContentSize: NSSize,
        contentSize: NSSize,
        frameAutosaveName: NSWindow.FrameAutosaveName = "JuiceStatsWindow"
    ) {
        if let window {
            // Refresh the content so the reopened window reflects current data.
            let currentSize = window.contentRect(forFrameRect: window.frame).size
            let targetSize: NSSize
            if currentSize.width < minimumContentSize.width
                || currentSize.height < minimumContentSize.height {
                targetSize = NSSize(
                    width: max(contentSize.width, minimumContentSize.width),
                    height: max(contentSize.height, minimumContentSize.height))
            } else {
                targetSize = currentSize
            }
            window.contentViewController = NSHostingController(rootView: root)
            window.title = title
            window.contentMinSize = minimumContentSize
            // Replacing a hosting controller can adopt the new root's fitting
            // size. Reapply the retained size (or the larger default) so
            // reopening does not overwrite the user's frame.
            window.setContentSize(targetSize)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = minimumContentSize
        window.setContentSize(contentSize)
        window.setFrameAutosaveName(frameAutosaveName)

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
