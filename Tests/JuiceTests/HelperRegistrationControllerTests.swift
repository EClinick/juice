import Foundation
import ServiceManagement
import Testing
@testable import Juice

@MainActor
@Suite("Helper registration lifecycle")
struct HelperRegistrationControllerTests {
    @Test("A never-registered notFound service is recovered and registered")
    func freshNotFoundRegisters() async {
        let service = FakeHelperService(statuses: [.notFound, .requiresApproval])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("An unregister failure does not prevent fresh registration")
    func unregisterFailureStillRegisters() async {
        let service = FakeHelperService(
            statuses: [.notFound, .requiresApproval],
            unregisterError: TestError.expected)
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("A stale approval is not adopted when notFound cleanup fails")
    func staleApprovalIsNotAdopted() async {
        let service = FakeHelperService(
            statuses: [.notFound, .requiresApproval],
            registerError: TestError.expected,
            unregisterError: TestError.expected)
        let suiteName = "HelperRegistrationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = makeController(service: service, defaults: defaults)

        await controller.prepare()

        #expect(controller.state == .requiresApproval)
        #expect(defaults.string(forKey: "registered_helper_app_build") == nil)
    }

    @Test("Registration reconciles a transient notFound status")
    func registrationReconcilesTransientNotFound() async {
        let service = FakeHelperService(
            statuses: [.notRegistered, .notFound, .requiresApproval])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("A real missing bundle payload does not attempt registration")
    func missingPayloadDoesNotRegister() async {
        let service = FakeHelperService(statuses: [.notFound])
        let controller = makeController(
            service: service,
            payloadError: "The helper executable is missing.")

        await controller.prepare()

        #expect(service.unregisterCallCount == 0)
        #expect(service.registerCallCount == 0)
        #expect(controller.state == .bundleMissing("The helper executable is missing."))
    }

    @Test("Persistent notFound becomes a diagnostic failure, not bundle missing")
    func persistentNotFoundIsDiagnosticFailure() async {
        let service = FakeHelperService(statuses: [.notFound])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.registerCallCount == 1)
        #expect(controller.state == .failed(
            "macOS accepted the helper registration but did not expose the service"))
    }

    @Test("A recovered enabled helper advances readiness once")
    func enabledRecoveryAdvancesReadiness() async {
        let service = FakeHelperService(statuses: [.notFound, .enabled])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(controller.state == .enabled)
        #expect(controller.readyGeneration == 1)
    }

    @Test("Approval to enabled refresh verifies the helper and advances once")
    func approvalRefreshVerifiesAndAdvancesOnce() async {
        let service = FakeHelperService(statuses: [.notRegistered, .requiresApproval])
        let controller = makeController(service: service)
        await controller.prepare()
        #expect(controller.state == .requiresApproval)

        service.setStatuses([.enabled, .enabled])
        await controller.refreshStatus()
        #expect(controller.state == .enabled)
        #expect(controller.readyGeneration == 1)

        service.setStatuses([.enabled])
        await controller.refreshStatus()
        #expect(controller.readyGeneration == 1)
    }

    @Test("Approval refresh with a mismatched helper reregisters without readiness")
    func approvalRefreshRejectsMismatchedHelper() async {
        let service = FakeHelperService(statuses: [.notRegistered, .requiresApproval])
        let controller = makeController(service: service, helperMatches: false)
        await controller.prepare()

        service.setStatuses([.enabled, .enabled, .requiresApproval])
        await controller.refreshStatus()

        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 2)
        #expect(controller.state == .requiresApproval)
        #expect(controller.readyGeneration == 0)
    }

    @Test("A notFound refresh routes through recovery")
    func notFoundRefreshRecovers() async {
        let service = FakeHelperService(
            statuses: [.notFound, .notFound, .requiresApproval])
        let controller = makeController(service: service)

        await controller.refreshStatus()

        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("Payload validator accepts only the expected executable")
    func payloadValidatorAcceptsExpectedExecutable() throws {
        let fixture = try HelperBundleFixture(bundleProgram:
            "Contents/Library/HelperTools/JuiceHelper")
        defer { fixture.remove() }

        #expect(HelperRegistrationController.bundledHelperValidationError(
            bundleURL: fixture.bundleURL) == nil)
    }

    @Test("Payload validator rejects a different executable path")
    func payloadValidatorRejectsDifferentExecutable() throws {
        let fixture = try HelperBundleFixture(bundleProgram:
            "Contents/Library/HelperTools/OtherHelper")
        defer { fixture.remove() }

        #expect(HelperRegistrationController.bundledHelperValidationError(
            bundleURL: fixture.bundleURL)
            == "The bundled launch-daemon property list is invalid.")
    }

    @Test("Payload validator rejects a missing helper executable")
    func payloadValidatorRejectsMissingExecutable() throws {
        let fixture = try HelperBundleFixture(
            bundleProgram: "Contents/Library/HelperTools/JuiceHelper",
            createExecutable: false)
        defer { fixture.remove() }

        #expect(HelperRegistrationController.bundledHelperValidationError(
            bundleURL: fixture.bundleURL)
            == "The bundled helper executable is missing or invalid.")
    }

    private func makeController(
        service: FakeHelperService,
        defaults: UserDefaults? = nil,
        payloadError: String? = nil,
        helperMatches: Bool = true
    ) -> HelperRegistrationController {
        let suiteName = "HelperRegistrationControllerTests.\(UUID().uuidString)"
        let isolatedDefaults = defaults ?? UserDefaults(suiteName: suiteName)!
        if defaults == nil {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
        }
        return HelperRegistrationController(
            service: service,
            defaults: isolatedDefaults,
            installedInApplications: { true },
            payloadValidationError: { payloadError },
            helperMatchesBundledPayload: { helperMatches },
            sleep: { _ in })
    }
}

@MainActor
private final class FakeHelperService: HelperServiceManaging {
    private var statuses: [SMAppService.Status]
    private let registerError: Error?
    private let unregisterError: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        statuses: [SMAppService.Status],
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.statuses = statuses
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var status: SMAppService.Status {
        guard statuses.count > 1 else { return statuses[0] }
        return statuses.removeFirst()
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
    }

    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) {
        unregisterCallCount += 1
        completionHandler(unregisterError)
    }

    func setStatuses(_ statuses: [SMAppService.Status]) {
        self.statuses = statuses
    }
}

private enum TestError: Error {
    case expected
}

private struct HelperBundleFixture {
    let bundleURL: URL

    init(bundleProgram: String, createExecutable: Bool = true) throws {
        bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JuiceHelperFixture.\(UUID().uuidString).app")
        let plistURL = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/com.eclinick.juice.helper.plist")
        let helperURL = bundleURL.appendingPathComponent(bundleProgram)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if createExecutable {
            try FileManager.default.createDirectory(
                at: helperURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: helperURL.path, contents: Data())
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["BundleProgram": bundleProgram],
            format: .xml,
            options: 0)
        try plistData.write(to: plistURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}
