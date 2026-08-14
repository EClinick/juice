import AppKit
import SwiftUI

/// Hosts Juice's SwiftUI preferences in a retained AppKit window.
///
/// `MenuBarExtra` intentionally remains the app's only SwiftUI scene because
/// its removal-to-quit lifecycle isn't designed to coexist with other scene
/// types. A regular AppKit window matches the presentation model used by Stats.
@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    static let contentSize = NSSize(width: 660, height: 420)
    static let frameAutosaveName: NSWindow.FrameAutosaveName =
        "JuiceSettingsWindow"

    private(set) var window: NSWindow?
    private let makeRootView: () -> AnyView
    private let activateApplication: () -> Void
    private let refreshLaunchAtLogin: () -> Void
    private let centerWindow: @MainActor (NSWindow) -> Void
    private let autosaveName: NSWindow.FrameAutosaveName

    private init() {
        makeRootView = { AnyView(JuiceSettingsView()) }
        activateApplication = {
            NSApp.activate(ignoringOtherApps: true)
        }
        refreshLaunchAtLogin = {
            LaunchAtLoginController.shared.refresh()
        }
        centerWindow = { $0.center() }
        autosaveName = Self.frameAutosaveName
    }

    init(
        makeRootView: @escaping () -> AnyView,
        activateApplication: @escaping () -> Void,
        refreshLaunchAtLogin: @escaping () -> Void,
        centerWindow: @escaping @MainActor (NSWindow) -> Void,
        autosaveName: NSWindow.FrameAutosaveName
    ) {
        self.makeRootView = makeRootView
        self.activateApplication = activateApplication
        self.refreshLaunchAtLogin = refreshLaunchAtLogin
        self.centerWindow = centerWindow
        self.autosaveName = autosaveName
    }

    func show() {
        refreshLaunchAtLogin()
        activateApplication()

        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: makeRootView())
        let window = NSWindow(contentViewController: controller)
        window.title = "Juice Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        let restoredFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        window.setContentSize(Self.contentSize)
        window.isReleasedWhenClosed = false

        self.window = window
        if !restoredFrame {
            centerWindow(window)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
