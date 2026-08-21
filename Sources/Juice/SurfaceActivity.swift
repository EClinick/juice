import AppKit
import CoreGraphics
import SwiftUI

private struct JuiceSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the AppKit surface hosting this SwiftUI hierarchy is actually
    /// interactive. MenuBarExtra can retain its hierarchy after ordering its
    /// window out, so `onDisappear` alone is not a reliable visibility signal.
    var juiceSurfaceIsActive: Bool {
        get { self[JuiceSurfaceActiveKey.self] }
        set { self[JuiceSurfaceActiveKey.self] = newValue }
    }
}

/// Observes the AppKit window hosting a SwiftUI hierarchy. MenuBarExtra's
/// window is key exactly while its popover is presented. Observe both key and
/// occlusion changes because MenuBarExtra can order its panel out without
/// delivering a matching resign-key notification on every macOS release.
@MainActor
final class WindowActivityObserver: NSObject {
    private weak var window: NSWindow?
    private var onChange: (Bool) -> Void
    private var visibilityTask: Task<Void, Never>?
    private let sleep: (Duration) async -> Void
    private(set) var isActive = false

    init(
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onChange: @escaping (Bool) -> Void
    ) {
        self.sleep = sleep
        self.onChange = onChange
    }

    func updateHandler(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func observe(_ newWindow: NSWindow?) {
        guard window !== newWindow else {
            publish(newWindow.map(isActuallyActive) == true)
            return
        }
        stopObserving()
        window = newWindow
        guard let newWindow else {
            publish(false)
            return
        }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: newWindow)
        center.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: newWindow)
        center.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: newWindow)
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: newWindow)
        publish(isActuallyActive(newWindow))
    }

    func stopObserving() {
        visibilityTask?.cancel()
        visibilityTask = nil
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: window)
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: window)
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: window)
        }
        window = nil
        publish(false)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        publish(true)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        publish(false)
    }

    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            publish(false)
            return
        }
        publish(isActuallyActive(window))
    }

    @objc private func windowWillClose(_ notification: Notification) {
        publish(false)
    }

    private func publish(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onChange(active)
        if active {
            startVisibilityWatch()
        } else {
            visibilityTask?.cancel()
            visibilityTask = nil
        }
    }

    /// MenuBarExtra can order its retained panel out without sending any of
    /// NSWindow's key, close, or occlusion notifications. Poll only while the
    /// surface is active so that this OS gap cannot leave animation or sampling
    /// work running after the panel disappears.
    private func startVisibilityWatch() {
        visibilityTask?.cancel()
        let sleep = sleep
        visibilityTask = Task { @MainActor [weak self, weak window] in
            var consecutiveOffScreenChecks = 0
            while !Task.isCancelled {
                await sleep(.milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                guard let window else {
                    self.publish(false)
                    return
                }
                if self.isOnScreen(window) {
                    consecutiveOffScreenChecks = 0
                    continue
                }
                consecutiveOffScreenChecks += 1
                guard consecutiveOffScreenChecks >= 2 else { continue }
                self.publish(false)
                return
            }
        }
    }

    /// MenuBarExtra's retained NSWindow can continue claiming `isVisible` and
    /// `isKeyWindow` after it has been ordered out. WindowServer's on-screen
    /// list reflects the presentation state that matters for energy usage.
    private func isOnScreen(_ window: NSWindow) -> Bool {
        let descriptions = CGWindowListCopyWindowInfo(
            .optionIncludingWindow,
            CGWindowID(window.windowNumber)) as? [[String: Any]]
        return descriptions?.first?[kCGWindowIsOnscreen as String] as? Bool == true
    }

    private func isActuallyActive(_ window: NSWindow) -> Bool {
        window.isKeyWindow && isOnScreen(window)
    }
}

private final class WindowActivityProbeView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

struct WindowActivityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    @MainActor
    final class Coordinator {
        let observer: WindowActivityObserver

        init(onChange: @escaping (Bool) -> Void) {
            observer = WindowActivityObserver(onChange: onChange)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowActivityProbeView(frame: .zero)
        view.windowChanged = { [weak observer = context.coordinator.observer] window in
            observer?.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.observer.updateHandler(onChange)
        context.coordinator.observer.observe(nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.observer.stopObserving()
    }
}
