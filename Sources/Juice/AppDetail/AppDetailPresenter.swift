import SwiftUI
import AppKit
import JuiceCore

/// Opens and manages the per-app energy detail window.
///
/// Mirrors ``StatsWindowPresenter``: a single window is reused across
/// invocations, with its content (and title) swapped to the requested app.
final class AppDetailPresenter {
    static let shared = AppDetailPresenter()

    private var window: NSWindow?

    private init() {}

    func show(appKey: String, displayName: String, range: EnergyRange) {
        NSApp.activate(ignoringOtherApps: true)

        // One captured window end anchors the interval query, the chart's
        // x-domain, and the explanation's hour count.
        let windowEnd = Date()
        let windowStart = PowerlogEnergySource.rangeStart(for: range, now: windowEnd)
        let windowHours = max(1, Int((windowEnd.timeIntervalSince(windowStart) / 3600)
            .rounded(.up)))

        let source = PowerlogEnergySource()
        let root = AppDetailView(
            displayName: displayName,
            bundleId: appKey,
            rangeLabel: range.rawValue,
            windowStart: windowStart,
            windowEnd: windowEnd,
            windowHours: windowHours,
            provider: {
                let intervals = try await source.appIntervals(appKey: appKey, range: range)
                return BreakdownBuilder.build(intervals: intervals, appKey: appKey)
            }
        )

        let title = "Juice - \(displayName)"

        if let window {
            // Refresh the content so the reopened window shows the requested app.
            window.contentViewController = NSHostingController(rootView: root)
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 560))
        window.setFrameAutosaveName("JuiceAppDetailWindow")
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.center()
    }
}
