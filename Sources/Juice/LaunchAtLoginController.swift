import AppKit
import Combine
import Foundation
import ServiceManagement

/// Small seam around the main-app login item so settings behavior can be
/// exercised without changing the test process's real login items.
@MainActor
protocol LaunchAtLoginServiceManaging: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServiceManaging {}

/// Keeps Juice's launch-at-login setting synchronized with ServiceManagement.
@MainActor
final class LaunchAtLoginController: NSObject, ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    private let service: LaunchAtLoginServiceManaging
    private let openSystemSettingsAction: () -> Void

    init(
        service: LaunchAtLoginServiceManaging = SMAppService.mainApp,
        notificationCenter: NotificationCenter? = .default,
        openSystemSettingsAction: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.service = service
        self.openSystemSettingsAction = openSystemSettingsAction
        status = service.status
        super.init()

        notificationCenter?.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil

        if enabled {
            guard status != .enabled, status != .requiresApproval else { return }
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
        }

        isChanging = true
        var operationError: Error?
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            operationError = error
        }

        status = service.status
        isChanging = false

        guard let operationError else { return }
        // ServiceManagement can report a race after the requested transition
        // has already landed. Effective status wins over the thrown error.
        let reachedRequestedState = enabled
            ? isEnabled || requiresApproval
            : status == .notRegistered
        guard !reachedRequestedState else { return }
        let action = enabled ? "enable" : "disable"
        errorMessage = "Could not \(action) launch at login: \(operationError.localizedDescription)"
    }

    func refresh() {
        let previousStatus = status
        status = service.status
        if status != previousStatus {
            errorMessage = nil
        }
    }

    func openSystemSettings() {
        openSystemSettingsAction()
    }

    @objc private func appDidBecomeActive() {
        refresh()
    }
}
