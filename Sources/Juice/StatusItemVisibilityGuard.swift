import AppKit

/// Keeps the menu bar icon alive through a stale system-side "item removed"
/// record.
///
/// macOS remembers per bundle identifier that a status item was removed from
/// the menu bar (for example by cmd-dragging it off). The record is held by a
/// SIP-protected system daemon, survives ControlCenter restarts, and is not
/// cleared by the System Settings > Menu Bar toggle. On the next launch the
/// system pushes a hide action to the freshly created item roughly 150 ms in,
/// and MenuBarExtra's built-in termination-on-removal behavior then quits the
/// app before the icon ever appears - permanently, on every launch.
///
/// Launching the app is an unambiguous request to show the icon again, so
/// during startup this guard locates MenuBarExtra's underlying NSStatusItem,
/// temporarily disables termination-on-removal, and re-asserts visibility
/// whenever the system hides the item. A client-side `isVisible = true` wins
/// against the stale record and sticks (verified on macOS 26.4). Once startup
/// has settled, the standard remove-to-quit behavior is restored so users can
/// still cmd-drag the icon away to quit the app.
@MainActor
enum StatusItemVisibilityGuard {
    /// How long after launch the system's stale hide action is fought off.
    /// The push arrives ~150 ms after item registration; a few seconds leaves
    /// generous headroom without noticeably delaying remove-to-quit.
    private static let protectionWindow: TimeInterval = 3

    /// Polling cadence and budget for locating the status item. MenuBarExtra
    /// creates it during scene setup, typically well under a second in.
    private static let locateInterval: TimeInterval = 0.05
    private static let locateAttempts = 60

    private static var observation: NSKeyValueObservation?

    static func engage() {
        locateStatusItem(attemptsLeft: locateAttempts)
    }

    private static func locateStatusItem(attemptsLeft: Int) {
        guard let item = menuBarExtraStatusItem() else {
            guard attemptsLeft > 0 else {
                NSLog("Juice: menu bar item never materialized; visibility guard inactive")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + locateInterval) {
                locateStatusItem(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        protect(item)
    }

    private static func protect(_ item: NSStatusItem) {
        // Suppress termination first: the hide action may already be in
        // flight, and it must not find termination-on-removal armed.
        item.behavior = []
        if !item.isVisible {
            NSLog("Juice: menu bar item was hidden at launch; re-asserting visibility")
            item.isVisible = true
        }
        observation = item.observe(\.isVisible, options: [.new]) { item, _ in
            guard !item.isVisible else { return }
            NSLog("Juice: system hid the menu bar item during startup; re-asserting visibility")
            DispatchQueue.main.async { item.isVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + protectionWindow) {
            observation = nil
            item.behavior = .terminationOnRemoval
        }
    }

    /// MenuBarExtra offers no public handle to its NSStatusItem, so find it
    /// through the status bar window. Every check degrades gracefully: if
    /// AppKit renames the window class or property, the guard simply stays
    /// inactive and launch behaves as it did before this workaround.
    private static func menuBarExtraStatusItem() -> NSStatusItem? {
        for window in NSApp.windows {
            guard window.className == "NSStatusBarWindow",
                window.responds(to: Selector(("statusItem"))),
                let item = window.value(forKey: "statusItem") as? NSStatusItem else {
                continue
            }
            return item
        }
        return nil
    }
}
