import AppKit
import ServiceManagement
import Testing
@testable import Juice

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginControllerTests {
    @Test("Enabling registers the main app and publishes the resulting status")
    func enable() {
        let service = FakeLaunchAtLoginService(
            status: .notRegistered,
            statusAfterRegister: .enabled)
        let controller = makeController(service: service)
        service.onRegister = {
            #expect(controller.isChanging)
        }

        controller.setEnabled(true)

        #expect(service.registerCallCount == 1)
        #expect(service.unregisterCallCount == 0)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(!controller.isChanging)
        #expect(controller.errorMessage == nil)
    }

    @Test("Disabling unregisters an enabled main app")
    func disable() {
        let service = FakeLaunchAtLoginService(
            status: .enabled,
            statusAfterUnregister: .notRegistered)
        let controller = makeController(service: service)

        controller.setEnabled(false)

        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 1)
        #expect(controller.status == .notRegistered)
        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(!controller.isChanging)
        #expect(controller.errorMessage == nil)
    }

    @Test("Approval-required registration is an actionable state, not an error")
    func approvalRequired() {
        let service = FakeLaunchAtLoginService(
            status: .notRegistered,
            statusAfterRegister: .requiresApproval,
            registerError: TestFailure.permissionDenied)
        let controller = makeController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCallCount == 1)
        #expect(controller.status == .requiresApproval)
        #expect(!controller.isEnabled)
        #expect(controller.requiresApproval)
        #expect(controller.errorMessage == nil)
    }

    @Test("A registration failure is surfaced without inventing enabled state")
    func enableFailure() {
        let service = FakeLaunchAtLoginService(
            status: .notRegistered,
            registerError: TestFailure.expected)
        let controller = makeController(service: service)

        controller.setEnabled(true)

        #expect(controller.status == .notRegistered)
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage ==
            "Could not enable launch at login: Expected test failure")
        #expect(!controller.isChanging)
    }

    @Test("An already-landed registration wins over a race error")
    func enableRaceUsesEffectiveStatus() {
        let service = FakeLaunchAtLoginService(
            status: .notRegistered,
            statusAfterRegister: .enabled,
            registerError: TestFailure.expected)
        let controller = makeController(service: service)

        controller.setEnabled(true)

        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    @Test("An unregister failure preserves service truth and surfaces the error")
    func disableFailure() {
        let service = FakeLaunchAtLoginService(
            status: .enabled,
            unregisterError: TestFailure.expected)
        let controller = makeController(service: service)

        controller.setEnabled(false)

        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.errorMessage ==
            "Could not disable launch at login: Expected test failure")
        #expect(!controller.isChanging)
    }

    @Test("An already-landed unregister wins over a race error")
    func disableRaceUsesEffectiveStatus() {
        let service = FakeLaunchAtLoginService(
            status: .enabled,
            statusAfterUnregister: .notRegistered,
            unregisterError: TestFailure.expected)
        let controller = makeController(service: service)

        controller.setEnabled(false)

        #expect(!controller.isEnabled)
        #expect(controller.status == .notRegistered)
        #expect(controller.errorMessage == nil)
    }

    @Test("Refresh adopts a status changed outside Juice")
    func externalRefresh() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = makeController(service: service)

        service.status = .enabled
        controller.refresh()

        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(!controller.requiresApproval)
    }

    @Test("Application activation refreshes externally changed approval")
    func activationRefresh() {
        let center = NotificationCenter()
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(
            service: service,
            notificationCenter: center)

        service.status = .enabled
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
    }

    @Test("System Settings action uses the injected opener")
    func openSystemSettings() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        var openCount = 0
        let controller = LaunchAtLoginController(
            service: service,
            notificationCenter: nil,
            openSystemSettingsAction: { openCount += 1 })

        controller.openSystemSettings()

        #expect(openCount == 1)
    }

    private func makeController(
        service: FakeLaunchAtLoginService
    ) -> LaunchAtLoginController {
        LaunchAtLoginController(service: service, notificationCenter: nil)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServiceManaging {
    var status: SMAppService.Status
    var onRegister: (() -> Void)?

    private let statusAfterRegister: SMAppService.Status?
    private let statusAfterUnregister: SMAppService.Status?
    private let registerError: Error?
    private let unregisterError: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: SMAppService.Status,
        statusAfterRegister: SMAppService.Status? = nil,
        statusAfterUnregister: SMAppService.Status? = nil,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.statusAfterUnregister = statusAfterUnregister
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCallCount += 1
        onRegister?()
        if let statusAfterRegister {
            status = statusAfterRegister
        }
        if let registerError { throw registerError }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
        if let unregisterError { throw unregisterError }
    }
}

private enum TestFailure: LocalizedError {
    case expected
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .expected:
            "Expected test failure"
        case .permissionDenied:
            "Approval is required"
        }
    }
}
