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
/// app before the icon ever appears - permanently, on every launch. The same
/// push is re-delivered whenever the status item scene reconnects, such as
/// after a ControlCenter restart, so the protection cannot be limited to a
/// startup window.
///
/// This guard locates MenuBarExtra's underlying NSStatusItem, permanently
/// disables AppKit's termination-on-removal, and classifies every hide by
/// when it arrives:
/// - within the startup window it is the stale record replaying, so the item
///   is re-asserted visible (a client-side `isVisible = true` wins and
///   sticks; verified on macOS 26.4);
/// - after the window it is a deliberate removal by the user, so the app
///   quits itself, preserving the standard menu-bar-app UX that
///   termination-on-removal provided.
@MainActor
enum StatusItemVisibilityGuard {
    /// The stale push arrives ~150 ms after the item registers; a few seconds
    /// of re-asserting leaves generous headroom without overriding a genuine
    /// removal for long.
    private static let startupWindow: TimeInterval = 5

    /// Polling cadence and budget for locating the status item. MenuBarExtra
    /// creates it during scene setup, typically well under a second in.
    private static let locateInterval: TimeInterval = 0.05
    private static let locateAttempts = 60

    private static var observation: NSKeyValueObservation?
    private static var protectionExpiry = Date.distantPast

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
        // Suppress AppKit's own termination first: the stale hide action may
        // already be in flight, and it must not find termination-on-removal
        // armed. The guard takes over the remove-to-quit role below.
        item.behavior = []
        protectionExpiry = Date().addingTimeInterval(startupWindow)
        if !item.isVisible {
            NSLog("Juice: menu bar item was hidden at launch; re-asserting visibility")
            item.isVisible = true
        }
        observation = item.observe(\.isVisible, options: [.new]) { item, _ in
            guard !item.isVisible else { return }
            DispatchQueue.main.async { hidden(item) }
        }
    }

    private static func hidden(_ item: NSStatusItem) {
        if Date() < protectionExpiry {
            NSLog("Juice: system hid the menu bar item during startup; re-asserting visibility")
            item.isVisible = true
        } else {
            // A hide this long after startup is the user removing the icon
            // (cmd-drag or the System Settings toggle). A menu-bar-only app
            // without its icon is unreachable, so quit like MenuBarExtra's
            // standard termination-on-removal would have.
            NSLog("Juice: menu bar item was removed; quitting")
            NSApp.terminate(nil)
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
