import Foundation
import ServiceManagement
import Testing
@testable import Juice

@MainActor
@Suite("Helper registration lifecycle")
struct HelperRegistrationControllerTests {
    @Test("A never-registered notFound service is recovered and registered")
    func freshNotFoundRegisters() async {
        let service = FakeHelperService(
            statuses: [.notFound, .requiresApproval],
            asyncUnregisterBehaviors: [.never])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 0)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("An arbitrary register error cannot adopt a stale approval state")
    func arbitraryRegistrationErrorDoesNotAdoptApproval() async {
        let service = FakeHelperService(
            statuses: [.notFound, .requiresApproval],
            registerErrors: [TestError.expected])
        let suiteName = "HelperRegistrationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = makeController(service: service, defaults: defaults)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 0)
        #expect(service.registerCallCount == 1)
        guard case .failed = controller.state else {
            Issue.record("Expected registration failure, got \(controller.state)")
            return
        }
        #expect(defaults.string(forKey: "registered_helper_app_build") == nil)
    }

    @Test("A successful notFound registration records the approval build")
    func successfulRegistrationRecordsApprovalBuild() async {
        let service = FakeHelperService(statuses: [.notFound, .requiresApproval])
        let suiteName = "HelperRegistrationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = makeController(service: service, defaults: defaults)

        await controller.prepare()

        #expect(controller.state == .requiresApproval)
        #expect(defaults.string(forKey: "registered_helper_app_build") != nil)
    }

    @Test("A launch-denied registration records the approval build")
    func launchDeniedRegistrationRecordsApprovalBuild() async {
        let service = FakeHelperService(
            statuses: [.notFound, .requiresApproval],
            registerErrors: [serviceManagementError(Int(kSMErrorLaunchDeniedByUser))])
        let suiteName = "HelperRegistrationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = makeController(service: service, defaults: defaults)

        await controller.prepare()

        #expect(controller.state == .requiresApproval)
        #expect(service.asynchronousUnregisterCallCount == 0)
        #expect(defaults.string(forKey: "registered_helper_app_build") != nil)
    }

    @Test("A stale notFound record is cleaned once after registration fails")
    func staleNotFoundIsCleanedOnce() async {
        let jobNotFound = NSError(
            domain: "SMAppServiceErrorDomain",
            code: Int(kSMErrorJobNotFound))
        let service = FakeHelperService(
            statuses: [.notFound, .notFound, .requiresApproval],
            registerErrors: [serviceManagementError(Int(kSMErrorAlreadyRegistered))],
            asyncUnregisterBehaviors: [.complete(jobNotFound)])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 2)
        #expect(controller.state == .requiresApproval)
    }

    @Test("A stale notFound cleanup failure stops registration")
    func staleNotFoundCleanupFailureStopsRegistration() async {
        let service = FakeHelperService(
            statuses: [.notFound, .notFound],
            registerErrors: [serviceManagementError(Int(kSMErrorAlreadyRegistered))],
            asyncUnregisterBehaviors: [.complete(TestError.expected)])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        guard case .failed(let message) = controller.state else {
            Issue.record("Expected cleanup failure, got \(controller.state)")
            return
        }
        #expect(message.hasPrefix("Could not clear stale helper registration:"))
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

        #expect(service.asynchronousUnregisterCallCount == 0)
        #expect(service.registerCallCount == 0)
        #expect(controller.state == .bundleMissing("The helper executable is missing."))
    }

    @Test("Persistent notFound becomes a diagnostic failure, not bundle missing")
    func persistentNotFoundIsDiagnosticFailure() async {
        let service = FakeHelperService(statuses: [.notFound])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 2)
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

        #expect(service.asynchronousUnregisterCallCount == 1)
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

        #expect(service.asynchronousUnregisterCallCount == 0)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("A missing async unregister callback times out instead of hanging")
    func missingUnregisterCallbackTimesOut() async {
        let service = FakeHelperService(
            statuses: [.enabled],
            asyncUnregisterBehaviors: [.never])
        let controller = makeController(
            service: service,
            helperMatches: false,
            unregisterTimeout: 0.01)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 0)
        guard case .failed(let message) = controller.state else {
            Issue.record("Expected timeout failure, got \(controller.state)")
            return
        }
        #expect(message.contains("did not finish unregistering"))
    }

    @Test("A missing callback blocks overlap even when status becomes missing")
    func missingCallbackBlocksUnsafeRetry() async {
        let service = FakeHelperService(
            statuses: [.enabled],
            asyncUnregisterBehaviors: [.never])
        let controller = makeController(
            service: service,
            helperMatches: false,
            unregisterTimeout: 0.01)

        await controller.prepare()
        guard case .failed = controller.state else {
            Issue.record("Expected first preparation to time out")
            return
        }

        service.setStatuses([.notFound])
        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 0)
        guard case .failed(let message) = controller.state else {
            Issue.record("Expected the unresolved operation to block retry")
            return
        }
        #expect(message.contains("restart your Mac"))
    }

    @Test("A stale notFound timeout cannot overlap a retry")
    func staleNotFoundTimeoutBlocksUnsafeRetry() async {
        let service = FakeHelperService(
            statuses: [.notFound, .notFound],
            registerErrors: [serviceManagementError(Int(kSMErrorAlreadyRegistered))],
            asyncUnregisterBehaviors: [.never])
        let controller = makeController(
            service: service,
            unregisterTimeout: 0.01)

        await controller.prepare()
        guard case .failed = controller.state else {
            Issue.record("Expected stale cleanup to time out")
            return
        }

        service.setStatuses([.notFound])
        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        guard case .failed(let message) = controller.state else {
            Issue.record("Expected unresolved stale cleanup to block retry")
            return
        }
        #expect(message.contains("restart your Mac"))
    }

    @Test("A timed-out unregister blocks overlap and recovers after its late callback")
    func lateUnregisterCallbackRecoversWithoutOverlap() async {
        let service = FakeHelperService(
            statuses: [.enabled],
            asyncUnregisterBehaviors: [.delayedSuccess(0.05)])
        let controller = makeController(
            service: service,
            helperMatches: false,
            unregisterTimeout: 0.01)

        await controller.prepare()
        guard case .failed = controller.state else {
            Issue.record("Expected first preparation to time out")
            return
        }

        service.setStatuses([.enabled])
        await controller.prepare()
        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 0)

        service.setStatuses([.notFound, .requiresApproval])
        try? await Task.sleep(for: .milliseconds(100))

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("An already-registered approval race is cleaned once from notFound")
    func alreadyRegisteredApprovalRaceIsRecovered() async {
        let service = FakeHelperService(
            statuses: [.notFound, .requiresApproval, .requiresApproval],
            registerErrors: [serviceManagementError(Int(kSMErrorAlreadyRegistered))])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 2)
        #expect(controller.state == .requiresApproval)
    }

    @Test("A post-unregister approval race records the current build")
    func postUnregisterApprovalRaceRecordsBuild() async {
        let service = FakeHelperService(
            statuses: [.enabled, .requiresApproval],
            registerErrors: [serviceManagementError(Int(kSMErrorAlreadyRegistered))])
        let suiteName = "HelperRegistrationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = makeController(
            service: service,
            defaults: defaults,
            helperMatches: false)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
        #expect(defaults.string(forKey: "registered_helper_app_build") != nil)
    }

    @Test("A missing job during update cleanup still registers")
    func missingJobDuringReregisterStillRegisters() async {
        let service = FakeHelperService(
            statuses: [.enabled, .requiresApproval],
            asyncUnregisterBehaviors: [
                .complete(serviceManagementError(Int(kSMErrorJobNotFound)))
            ])
        let controller = makeController(service: service, helperMatches: false)

        await controller.prepare()

        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("An invalid registration error never triggers stale cleanup")
    func invalidRegistrationErrorDoesNotCleanup() async {
        let service = FakeHelperService(
            statuses: [.notFound, .notFound, .requiresApproval],
            registerErrors: [serviceManagementError(Int(kSMErrorInvalidSignature))])
        let controller = makeController(service: service)

        await controller.prepare()

        #expect(service.statusReadCount == 2)
        #expect(service.asynchronousUnregisterCallCount == 0)
        #expect(service.registerCallCount == 1)
        guard case .failed = controller.state else {
            Issue.record("Expected invalid-signature failure, got \(controller.state)")
            return
        }
    }

    @Test("An enabled reconciliation fingerprints the helper only once")
    func enabledReconciliationFingerprintsOnce() async {
        var fingerprintChecks = 0
        let service = FakeHelperService(
            statuses: [.notRegistered, .enabled, .requiresApproval])
        let controller = makeController(
            service: service,
            helperMatchCheck: {
                fingerprintChecks += 1
                return false
            })

        await controller.prepare()

        #expect(fingerprintChecks == 1)
        #expect(service.asynchronousUnregisterCallCount == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test("Concurrent preparation is coalesced")
    func concurrentPreparationIsCoalesced() async {
        let gate = AsyncTestGate()
        let service = FakeHelperService(statuses: [.enabled])
        let controller = makeController(
            service: service,
            helperMatchCheck: {
                await gate.wait()
                return true
            })

        let firstPreparation = Task { @MainActor in
            await controller.prepare()
        }
        await gate.waitUntilEntered()
        await controller.prepare()
        #expect(service.statusReadCount == 1)

        await gate.open()
        await firstPreparation.value

        #expect(service.statusReadCount == 1)
        #expect(controller.state == .enabled)
        #expect(controller.readyGeneration == 1)
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
        helperMatches: Bool = true,
        helperMatchCheck: (() async -> Bool)? = nil,
        unregisterTimeout: TimeInterval = 5
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
            helperMatchesBundledPayload: helperMatchCheck ?? { helperMatches },
            sleep: { _ in },
            unregisterTimeout: unregisterTimeout)
    }
}

@MainActor
private final class FakeHelperService: HelperServiceManaging {
    private var statuses: [SMAppService.Status]
    private var registerErrors: [Error]
    private var asyncUnregisterBehaviors: [AsyncUnregisterBehavior]

    private(set) var registerCallCount = 0
    private(set) var asynchronousUnregisterCallCount = 0
    private(set) var statusReadCount = 0

    init(
        statuses: [SMAppService.Status],
        registerErrors: [Error] = [],
        asyncUnregisterBehaviors: [AsyncUnregisterBehavior] = [.complete(nil)]
    ) {
        self.statuses = statuses
        self.registerErrors = registerErrors
        self.asyncUnregisterBehaviors = asyncUnregisterBehaviors
    }

    var status: SMAppService.Status {
        statusReadCount += 1
        guard statuses.count > 1 else { return statuses[0] }
        return statuses.removeFirst()
    }

    func register() throws {
        registerCallCount += 1
        if !registerErrors.isEmpty { throw registerErrors.removeFirst() }
    }

    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) {
        asynchronousUnregisterCallCount += 1
        let behavior = asyncUnregisterBehaviors.count > 1
            ? asyncUnregisterBehaviors.removeFirst()
            : asyncUnregisterBehaviors[0]
        switch behavior {
        case .complete(let error):
            completionHandler(error)
        case .never:
            break
        case .delayedSuccess(let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                completionHandler(nil)
            }
        }
    }

    func setStatuses(_ statuses: [SMAppService.Status]) {
        self.statuses = statuses
    }
}

private enum AsyncUnregisterBehavior {
    case complete(Error?)
    case never
    case delayedSuccess(TimeInterval)
}

private enum TestError: Error {
    case expected
}

private func serviceManagementError(_ code: Int) -> NSError {
    NSError(domain: "SMAppServiceErrorDomain", code: code)
}

private actor AsyncTestGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
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
