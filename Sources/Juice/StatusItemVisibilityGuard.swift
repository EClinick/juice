import AppKit

/// Runs one bounded, timer-driven lookup chain at a time. A later request may
/// start a fresh chain after exhaustion, which lets a delayed MenuBarExtra
/// recover without allowing each live-power reading to create another timer.
@MainActor
final class CoalescingRetryLocator<Item> {
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    private let lookup: () -> Item?
    private let schedule: Scheduler
    private(set) var isLocating = false

    init(
        lookup: @escaping () -> Item?,
        schedule: @escaping Scheduler
    ) {
        self.lookup = lookup
        self.schedule = schedule
    }

    func request(
        retries: Int,
        onFound: @escaping (Item) -> Void,
        onExhausted: @escaping () -> Void
    ) {
        guard !isLocating else { return }
        isLocating = true
        attempt(
            retriesLeft: retries,
            onFound: onFound,
            onExhausted: onExhausted)
    }

    private func attempt(
        retriesLeft: Int,
        onFound: @escaping (Item) -> Void,
        onExhausted: @escaping () -> Void
    ) {
        if let item = lookup() {
            isLocating = false
            onFound(item)
            return
        }
        guard retriesLeft > 0 else {
            isLocating = false
            onExhausted()
            return
        }
        schedule { [weak self] in
            self?.attempt(
                retriesLeft: retriesLeft - 1,
                onFound: onFound,
                onExhausted: onExhausted)
        }
    }
}

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
    private static weak var protectedItem: NSStatusItem?
    /// A reading can arrive before MenuBarExtra materializes its status item.
    /// Retain only the formatted label and apply it when discovery succeeds.
    private static var pendingPowerLabel: String?
    private static let locator = CoalescingRetryLocator<NSStatusItem>(
        lookup: { menuBarExtraStatusItem() },
        schedule: { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + locateInterval) {
                action()
            }
        })

    static func engage() {
        requestStatusItemDiscovery(
            retries: locateAttempts,
            logsFailure: true)
    }

    private static func requestStatusItemDiscovery(
        retries: Int,
        logsFailure: Bool
    ) {
        locator.request(
            retries: retries,
            onFound: { item in
                protect(item)
            },
            onExhausted: {
                if logsFailure {
                    NSLog("Juice: menu bar item never materialized; visibility guard inactive")
                }
            })
    }

    private static func protect(_ item: NSStatusItem) {
        // Suppress AppKit's own termination first: the stale hide action may
        // already be in flight, and it must not find termination-on-removal
        // armed. The guard takes over the remove-to-quit role below.
        item.behavior = []
        protectedItem = item
        protectionExpiry = Date().addingTimeInterval(startupWindow)
        if !item.isVisible {
            NSLog("Juice: menu bar item was hidden at launch; re-asserting visibility")
            item.isVisible = true
        }
        observation = item.observe(\.isVisible, options: [.new]) { item, _ in
            guard !item.isVisible else { return }
            DispatchQueue.main.async { hidden(item) }
        }
        if let pendingPowerLabel {
            applyPowerLabel(pendingPowerLabel, to: item)
        }
    }

    /// Updates only the already-discovered AppKit status button instead of
    /// publishing a SwiftUI dependency from the app-scoped MenuBarExtra scene.
    /// Discovery remains centralized here; this adds no private selector or KVC
    /// path beyond the guard's existing status-item lookup.
    static func updatePowerLabel(_ text: String) {
        let formattedValueChanged = pendingPowerLabel != text
        pendingPowerLabel = text
        guard let item = protectedItem else {
            // The initial launch search may have exhausted before
            // MenuBarExtra materialized. Each later live reading performs one
            // coalesced lookup; this recovers the pending wattage without
            // creating another timer chain on every background sample.
            requestStatusItemDiscovery(retries: 0, logsFailure: false)
            return
        }
        guard formattedValueChanged
            || item.button?.title != text
            || item.button?.image != nil
            || item.button?.imagePosition != .noImage else { return }
        applyPowerLabel(text, to: item)
    }

    private static func applyPowerLabel(_ text: String, to item: NSStatusItem) {
        guard let button = item.button else { return }
        item.length = NSStatusItem.variableLength
        button.image = nil
        // MenuBarExtra created this button from an Image-only SwiftUI label.
        // Clearing the image does not necessarily change NSButton's layout
        // mode, so explicitly allow the replacement title to be drawn.
        button.imagePosition = .noImage
        button.title = text
        button.toolTip = "Juice current metered power: \(text)"
        button.setAccessibilityLabel("Juice current metered power")
        button.setAccessibilityValue(text)
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

    #if DEV_HELPER || DEBUG
    /// Deterministically opens the MenuBarExtra in development builds so the
    /// rendered popover can be verified without guessing a menu bar position.
    static func showPopoverForTesting(attemptsLeft: Int = 60) {
        guard let item = menuBarExtraStatusItem(), let button = item.button else {
            guard attemptsLeft > 0 else {
                NSLog("Juice: menu bar item unavailable for popover verification")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + locateInterval) {
                showPopoverForTesting(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        button.performClick(nil)
    }
    #endif

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
