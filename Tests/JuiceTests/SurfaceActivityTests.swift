import AppKit
import Testing
@testable import Juice

@MainActor
struct SurfaceActivityTests {
    @Test("Window key lifecycle drives surface activity without SwiftUI teardown")
    func keyLifecycleDrivesActivity() {
        var changes: [Bool] = []
        let observer = WindowActivityObserver { changes.append($0) }
        let window = NSWindow()
        let unrelatedWindow = NSWindow()

        observer.observe(window)
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: unrelatedWindow)
        #expect(changes.isEmpty)

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window)
        #expect(observer.isActive)
        #expect(changes == [true])

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window)
        #expect(!observer.isActive)
        #expect(changes == [true, false])

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window)
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window)
        #expect(changes == [true, false, true, false])

        observer.stopObserving()
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window)
        #expect(changes == [true, false, true, false])
    }

    @Test("Window close deactivates a retained surface")
    func closeDeactivatesSurface() {
        var changes: [Bool] = []
        let observer = WindowActivityObserver { changes.append($0) }
        let window = NSWindow()
        observer.observe(window)

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window)
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window)

        #expect(!observer.isActive)
        #expect(changes == [true, false])
    }

    @Test("Ordering a retained window off screen deactivates the surface")
    func occlusionChangeDeactivatesSurface() {
        var changes: [Bool] = []
        let observer = WindowActivityObserver { changes.append($0) }
        let window = NSWindow()
        observer.observe(window)

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window)
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window)

        #expect(!observer.isActive)
        #expect(changes == [true, false])
    }

    @Test("Visibility watch closes the MenuBarExtra notification gap")
    func visibilityWatchDeactivatesSurface() async throws {
        var changes: [Bool] = []
        let observer = WindowActivityObserver { changes.append($0) }
        let retainedHiddenWindow = NSWindow()
        observer.observe(retainedHiddenWindow)

        // Match the observed MenuBarExtra failure mode: the panel reported a
        // become-key transition, then ordered out without any matching event.
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: retainedHiddenWindow)
        #expect(observer.isActive)

        try await Task.sleep(for: .milliseconds(350))

        #expect(!observer.isActive)
        #expect(changes == [true, false])
    }

    @Test("A retained hidden window cannot reactivate during a SwiftUI update")
    func hiddenWindowUpdateStaysInactive() {
        var changes: [Bool] = []
        let observer = WindowActivityObserver { changes.append($0) }
        let retainedHiddenWindow = NSWindow()
        observer.observe(retainedHiddenWindow)

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: retainedHiddenWindow)
        observer.observe(retainedHiddenWindow)

        #expect(!observer.isActive)
        #expect(changes == [true, false])
    }
}
