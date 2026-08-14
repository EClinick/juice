import AppKit
import SwiftUI
import Testing
@testable import Juice

@MainActor
@Suite(.serialized)
struct SettingsWindowPresenterTests {
    @Test("Settings reuses one retained, fixed-size window")
    func reusesRetainedWindow() throws {
        var activationCount = 0
        var refreshCount = 0
        var centerCount = 0
        let autosaveName = NSWindow.FrameAutosaveName(
            "JuiceSettingsWindowTests-\(UUID().uuidString)")
        defer { NSWindow.removeFrame(usingName: autosaveName) }

        let presenter = SettingsWindowPresenter(
            makeRootView: { AnyView(Color.clear) },
            activateApplication: { activationCount += 1 },
            refreshLaunchAtLogin: { refreshCount += 1 },
            centerWindow: { _ in centerCount += 1 },
            autosaveName: autosaveName)

        presenter.show()
        let firstWindow = try #require(presenter.window)
        #expect(firstWindow.title == "Juice Settings")
        #expect(!firstWindow.styleMask.contains(.resizable))
        #expect(firstWindow.contentMinSize == SettingsWindowPresenter.contentSize)
        #expect(firstWindow.contentMaxSize == SettingsWindowPresenter.contentSize)
        #expect(centerCount == 1)

        firstWindow.close()
        presenter.show()
        let reopenedWindow = try #require(presenter.window)

        #expect(reopenedWindow === firstWindow)
        #expect(activationCount == 2)
        #expect(refreshCount == 2)
        #expect(centerCount == 1)
        reopenedWindow.orderOut(nil)
    }
}
