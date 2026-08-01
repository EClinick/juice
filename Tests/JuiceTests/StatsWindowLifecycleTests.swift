import AppKit
import SwiftUI
import Testing
@testable import Juice

@MainActor
@Suite(.serialized)
struct StatsWindowLifecycleTests {
    private let minimumSize = NSSize(width: 300, height: 200)
    private let defaultSize = NSSize(width: 640, height: 440)

    @Test("Only the managed window close detaches consumers and removes its host")
    func handlesOnlyManagedWindowClose() throws {
        var detachCount = 0
        let presenter = StatsWindowPresenter { detachCount += 1 }
        presenter.present(
            Color.clear,
            title: "Lifecycle test",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: uniqueAutosaveName())
        let managedWindow = try #require(presenter.window)
        let hostedController = managedWindow.contentViewController
        let unrelatedWindow = NSWindow()

        presenter.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: unrelatedWindow))

        #expect(detachCount == 0)
        #expect(managedWindow.contentViewController != nil)

        presenter.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: managedWindow))

        #expect(detachCount == 1)
        #expect(managedWindow.contentViewController !== hostedController)
        managedWindow.orderOut(nil)
    }

    @Test("Closing through AppKit cancels the hosted SwiftUI task")
    func closeCancelsHostedTask() async throws {
        let probe = HostedTaskProbe()
        var detachCount = 0
        let presenter = StatsWindowPresenter { detachCount += 1 }
        presenter.present(
            HostedTaskProbeView(probe: probe),
            title: "Task cancellation test",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: uniqueAutosaveName())
        let window = try #require(presenter.window)

        var taskStarted = false
        for _ in 0..<100 {
            taskStarted = await probe.started
            if taskStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(taskStarted)

        window.close()

        var taskCancelled = false
        for _ in 0..<100 {
            taskCancelled = await probe.cancelled
            if taskCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(detachCount == 1)
        #expect(taskCancelled)
    }

    @Test("Minimizing suspends work and restores the same state-owning host")
    func minimizeSuspendsHostedWork() async throws {
        let probe = HostedTaskProbe()
        var detachCount = 0
        let presenter = StatsWindowPresenter { detachCount += 1 }
        presenter.present(
            HostedTaskProbeView(probe: probe),
            title: "Minimize suspension test",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: uniqueAutosaveName())
        let window = try #require(presenter.window)
        let originalHost = window.contentViewController

        var taskStarted = false
        for _ in 0..<100 {
            taskStarted = await probe.started
            if taskStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(taskStarted)

        presenter.windowDidMiniaturize(
            Notification(name: NSWindow.didMiniaturizeNotification, object: window))
        let suspendedHost = window.contentViewController

        var taskCancelled = false
        for _ in 0..<100 {
            taskCancelled = await probe.cancelled
            if taskCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(detachCount == 1)
        #expect(suspendedHost !== originalHost)
        #expect(taskCancelled)

        presenter.windowDidDeminiaturize(
            Notification(name: NSWindow.didDeminiaturizeNotification, object: window))

        #expect(window.contentViewController === originalHost)
        var taskRestarted = false
        for _ in 0..<100 {
            taskRestarted = await probe.startedCount >= 2
            if taskRestarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(taskRestarted)
        window.orderOut(nil)
    }

    @Test("Closing a minimized window releases its suspended host")
    func closeWhileMinimizedReleasesHost() throws {
        let presenter = StatsWindowPresenter(detachStatsConsumers: {})
        presenter.present(
            Color.clear,
            title: "Minimized close test",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: uniqueAutosaveName())
        let window = try #require(presenter.window)
        let originalHost = window.contentViewController

        presenter.windowDidMiniaturize(
            Notification(name: NSWindow.didMiniaturizeNotification, object: window))
        #expect(window.contentViewController !== originalHost)

        presenter.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window))
        presenter.windowDidDeminiaturize(
            Notification(name: NSWindow.didDeminiaturizeNotification, object: window))

        #expect(window.contentViewController !== originalHost)
        window.orderOut(nil)
    }

    @Test("A closed retained window is reused with a fresh host and preserved size")
    func reopensRetainedWindow() throws {
        let presenter = StatsWindowPresenter(detachStatsConsumers: {})
        let autosaveName = uniqueAutosaveName()
        presenter.present(
            Color.red,
            title: "First",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: autosaveName)
        let originalWindow = try #require(presenter.window)
        #expect(originalWindow.frameAutosaveName == autosaveName)
        originalWindow.setContentSize(NSSize(width: 820, height: 610))

        presenter.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: originalWindow))
        let discardedHost = originalWindow.contentViewController

        presenter.present(
            Color.blue,
            title: "Second",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: uniqueAutosaveName())
        let reopenedWindow = try #require(presenter.window)

        #expect(reopenedWindow === originalWindow)
        #expect(reopenedWindow.contentViewController != nil)
        #expect(reopenedWindow.contentViewController !== discardedHost)
        #expect(reopenedWindow.title == "Second")
        expectSize(
            reopenedWindow.contentRect(forFrameRect: reopenedWindow.frame).size,
            equals: NSSize(width: 820, height: 610))
        reopenedWindow.orderOut(nil)
    }

    @Test("Visible presentations reuse one managed window")
    func reusesVisibleWindow() throws {
        let presenter = StatsWindowPresenter(detachStatsConsumers: {})
        let autosaveName = uniqueAutosaveName()
        presenter.present(
            Color.red,
            title: "Stats & Settings",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: autosaveName)
        let originalWindow = try #require(presenter.window)
        let originalHost = originalWindow.contentViewController
        originalWindow.setContentSize(NSSize(width: 810, height: 590))

        presenter.present(
            Color.blue,
            title: "Stats & Settings",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: autosaveName)
        let reusedWindow = try #require(presenter.window)

        #expect(reusedWindow === originalWindow)
        #expect(reusedWindow.contentViewController !== originalHost)
        #expect(reusedWindow.title == "Stats & Settings")
        expectSize(
            reusedWindow.contentRect(forFrameRect: reusedWindow.frame).size,
            equals: NSSize(width: 810, height: 590))
        reusedWindow.orderOut(nil)
    }

    @Test("A saved frame restores its content size on first presentation")
    func restoresAutosavedContentSize() throws {
        let autosaveName = uniqueAutosaveName()
        defer { NSWindow.removeFrame(usingName: autosaveName) }
        let savedContentSize = NSSize(width: 780, height: 520)
        let seedWindow = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: savedContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        seedWindow.saveFrame(usingName: autosaveName)

        let presenter = StatsWindowPresenter(detachStatsConsumers: {})
        presenter.present(
            Color.clear,
            title: "Restored",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: autosaveName)
        let restoredWindow = try #require(presenter.window)

        expectSize(
            restoredWindow.contentRect(forFrameRect: restoredWindow.frame).size,
            equals: savedContentSize)
        restoredWindow.orderOut(nil)
    }

    @Test("Reopening grows content that is below a new minimum")
    func growsContentForNewMinimum() throws {
        let presenter = StatsWindowPresenter(detachStatsConsumers: {})
        presenter.present(
            Color.clear,
            title: "Small",
            minimumContentSize: minimumSize,
            contentSize: defaultSize,
            frameAutosaveName: uniqueAutosaveName())
        let window = try #require(presenter.window)
        window.setContentSize(defaultSize)
        presenter.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window))

        let largerMinimum = NSSize(width: 860, height: 560)
        let largerDefault = NSSize(width: 940, height: 600)
        presenter.present(
            Color.clear,
            title: "Large",
            minimumContentSize: largerMinimum,
            contentSize: largerDefault,
            frameAutosaveName: uniqueAutosaveName())

        expectSize(
            window.contentRect(forFrameRect: window.frame).size,
            equals: largerDefault)
        #expect(window.contentMinSize == largerMinimum)
        window.orderOut(nil)
    }

    private func uniqueAutosaveName() -> NSWindow.FrameAutosaveName {
        "StatsWindowLifecycleTests-\(UUID().uuidString)"
    }

    private func expectSize(
        _ actual: NSSize,
        equals expected: NSSize,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual.width - expected.width) < 0.5,
            sourceLocation: sourceLocation)
        #expect(
            abs(actual.height - expected.height) < 0.5,
            sourceLocation: sourceLocation)
    }
}

private actor HostedTaskProbe {
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0
    var started: Bool { startedCount > 0 }
    var cancelled: Bool { cancelledCount > 0 }

    func run() async {
        startedCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelledCount += 1
        } catch {
            Issue.record("Unexpected hosted task error: \(error)")
        }
    }
}

private struct HostedTaskProbeView: View {
    let probe: HostedTaskProbe

    var body: some View {
        Color.clear
            .task {
                await probe.run()
            }
    }
}
