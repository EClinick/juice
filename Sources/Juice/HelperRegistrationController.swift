import Foundation
import AppKit
import ServiceManagement
import JuiceXPCShared

/// User-facing lifecycle state for the bundled privileged helper.
enum HelperRegistrationState: Equatable {
    case checking
    case registering
    case enabled
    case requiresApproval
    case needsApplicationInstall
    case notRegistered
    case bundleMissing(String)
    case failed(String)
}

/// Small seam around `SMAppService` so lifecycle transitions can be exercised
/// without registering a real root daemon in the test process.
@MainActor
protocol HelperServiceManaging: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension SMAppService: HelperServiceManaging {}

/// Registers the bundled launch daemon, tracks approval, and re-registers it
/// after an app update so launchd never keeps serving an older helper payload.
@MainActor
final class HelperRegistrationController: NSObject, ObservableObject {
    static let shared = HelperRegistrationController()

    @Published private(set) var state: HelperRegistrationState = .checking
    /// Advances only when a user/recovery transition makes the helper newly
    /// usable, so views can retry data without looping on ordinary error checks.
    @Published private(set) var readyGeneration = 0

    private let service: HelperServiceManaging
    private let defaults: UserDefaults
    private let installedInApplications: () -> Bool
    private let payloadValidationError: () -> String?
    private let helperMatchesBundledPayload: () async -> Bool
    private let sleep: (Duration) async -> Void
    private let unregisterTimeout: TimeInterval
    private let registeredBuildKey = "registered_helper_app_build"
    private var isPreparing = false
    private var pendingUnregisterOperationID: UUID?
    private var needsLateUnregisterRecovery = false

    init(
        service: HelperServiceManaging = SMAppService.daemon(
            plistName: JuiceXPC.daemonPlistName),
        defaults: UserDefaults = .standard,
        installedInApplications: (() -> Bool)? = nil,
        payloadValidationError: (() -> String?)? = nil,
        helperMatchesBundledPayload: (() async -> Bool)? = nil,
        sleep: ((Duration) async -> Void)? = nil,
        unregisterTimeout: TimeInterval = 5
    ) {
        self.service = service
        self.defaults = defaults
        self.installedInApplications = installedInApplications
            ?? { Self.isInstalledInApplications }
        self.payloadValidationError = payloadValidationError
            ?? { Self.bundledHelperValidationError() }
        self.helperMatchesBundledPayload = helperMatchesBundledPayload
            ?? { await Self.activeHelperMatchesBundledHelper() }
        self.sleep = sleep ?? { duration in try? await Task.sleep(for: duration) }
        self.unregisterTimeout = unregisterTimeout
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    /// Called at app launch. First installs the service registration, then on
    /// later app builds refreshes it as required by SMAppService.
    func prepare() async {
        guard !isPreparing else { return }
        let stateBeforePreparation = state
        isPreparing = true
        defer {
            isPreparing = false
            if state == .enabled,
                stateBeforePreparation != .enabled {
                readyGeneration += 1
            }
            scheduleLateUnregisterRecoveryIfPossible()
        }
        state = .checking
        guard installedInApplications() else {
            state = .needsApplicationInstall
            return
        }
        if let payloadError = payloadValidationError() {
            state = .bundleMissing(payloadError)
            return
        }
        guard let status = serviceStatusResolvingPendingUnregister() else { return }
        let currentBuild = Self.currentAppBuild
        let registeredBuild = defaults.string(forKey: registeredBuildKey)

        switch status {
        case .notRegistered:
            await register(currentBuild: currentBuild)
        case .enabled:
            if await helperMatchesBundledPayload() {
                defaults.set(currentBuild, forKey: registeredBuildKey)
                apply(status)
            } else {
                await reregister(currentBuild: currentBuild)
            }
        case .requiresApproval:
            if registeredBuild == currentBuild {
                apply(status)
            } else {
                await reregister(currentBuild: currentBuild)
            }
        case .notFound:
            // `.notFound` is also the normal status for a service that has
            // never been registered. Register first; unregistering an absent
            // job through the async API can fail to deliver its callback.
            await register(
                currentBuild: currentBuild,
                recoverStaleNotFound: true)
        @unknown default:
            state = .failed("Unknown helper service status")
        }
    }

    /// Re-read approval state after returning from System Settings.
    func refresh() {
        Task { await refreshStatus() }
    }

    /// Async implementation exposed internally so lifecycle transitions can
    /// be verified deterministically by tests.
    func refreshStatus() async {
        guard !isPreparing else { return }
        let previousState = state
        guard installedInApplications() else {
            state = .needsApplicationInstall
            return
        }
        guard let status = serviceStatusResolvingPendingUnregister() else { return }
        if status == .notFound {
            if let payloadError = payloadValidationError() {
                state = .bundleMissing(payloadError)
            } else {
                await prepare()
            }
            return
        }
        if status == .enabled, previousState != .enabled {
            await prepare()
            return
        }
        apply(status)
        if state == .enabled, previousState != .enabled {
            readyGeneration += 1
        }
    }

    /// Retry registration after a recoverable failure.
    func retry() {
        Task { await prepare() }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func appDidBecomeActive() {
        refresh()
    }

    private func register(
        currentBuild: String,
        recoverStaleNotFound: Bool = false,
        recoverPayloadMismatch: Bool = true,
        adoptAlreadyRegisteredApproval: Bool = false
    ) async {
        state = .registering
        var lastError: Error?
        var performedStaleCleanup = false
        let retryDelays: [Duration] = [.zero, .milliseconds(150), .milliseconds(500)]

        for (attempt, delay) in retryDelays.enumerated() {
            if delay != .zero { await sleep(delay) }
            do {
                try service.register()
                switch await reconcileRegisteredStatus(currentBuild: currentBuild) {
                case .settled, .unknown:
                    return
                case .payloadMismatch:
                    guard recoverPayloadMismatch else { return }
                    await reregister(currentBuild: currentBuild)
                    return
                case .persistentMissing:
                    guard recoverStaleNotFound,
                          !performedStaleCleanup,
                          attempt < retryDelays.count - 1 else { return }
                    guard await cleanupStaleNotFoundRegistration() else { return }
                    performedStaleCleanup = true
                    state = .registering
                    continue
                }
            } catch {
                lastError = error
                let statusAfterError = service.status
                // A register call can report an already-registered race even
                // after installing the new payload. Only adopt an enabled job
                // after its running executable proves it matches our bundle.
                if statusAfterError == .enabled,
                   Self.isAlreadyRegisteredError(error) {
                    if await helperMatchesBundledPayload() {
                        defaults.set(currentBuild, forKey: registeredBuildKey)
                        apply(statusAfterError)
                    } else if recoverPayloadMismatch {
                        await reregister(currentBuild: currentBuild)
                    } else {
                        state = .failed("macOS is still running a different helper payload")
                    }
                    return
                }
                if statusAfterError == .requiresApproval,
                   Self.isLaunchDeniedError(error) {
                    // A launch-denied result is the documented signal that
                    // this registration reached the user-approval boundary.
                    defaults.set(currentBuild, forKey: registeredBuildKey)
                    state = .requiresApproval
                    return
                }
                if Self.isAlreadyRegisteredError(error) {
                    let staleStatus = statusAfterError == .notFound
                        || statusAfterError == .requiresApproval
                    if staleStatus,
                       recoverStaleNotFound,
                       !performedStaleCleanup,
                       attempt < retryDelays.count - 1 {
                        guard await cleanupStaleNotFoundRegistration() else { return }
                        performedStaleCleanup = true
                        state = .registering
                        continue
                    }
                    if statusAfterError == .requiresApproval {
                        if adoptAlreadyRegisteredApproval {
                            defaults.set(currentBuild, forKey: registeredBuildKey)
                        }
                        state = .requiresApproval
                        return
                    }
                }
                guard attempt < retryDelays.count - 1,
                      Self.isTransientRegistrationError(error) else {
                    state = .failed(error.localizedDescription)
                    return
                }
            }
        }

        state = .failed(lastError?.localizedDescription ?? "Registration failed")
    }

    /// A reset Background Task Management database can leave registration in a
    /// contradictory `.notFound` state. Only after a direct register attempt
    /// fails do we perform one bounded cleanup and retry. The completion API is
    /// required here because it is the point at which re-registration is safe.
    private func cleanupStaleNotFoundRegistration() async -> Bool {
        do {
            try await unregisterWithTimeout()
            return true
        } catch where Self.isJobNotFoundError(error) {
            // The cleanup target disappearing is the desired end state.
            return true
        } catch {
            state = .failed(
                "Could not clear stale helper registration: \(error.localizedDescription)")
            return false
        }
    }

    /// Service Management may lag briefly after accepting registration. Avoid
    /// turning one intermediate `.notFound` sample into a permanent failure.
    private func reconcileRegisteredStatus(
        currentBuild: String
    ) async -> HelperRegistrationReconciliation {
        let retryDelays: [Duration] = [
            .zero, .milliseconds(150), .milliseconds(500), .seconds(1)
        ]

        for delay in retryDelays {
            if delay != .zero { await sleep(delay) }
            let status = service.status
            switch status {
            case .enabled:
                if await helperMatchesBundledPayload() {
                    defaults.set(currentBuild, forKey: registeredBuildKey)
                    state = .enabled
                    return .settled
                }
                state = .failed("macOS is running a different helper payload")
                return .payloadMismatch
            case .requiresApproval:
                defaults.set(currentBuild, forKey: registeredBuildKey)
                state = .requiresApproval
                return .settled
            case .notRegistered, .notFound:
                continue
            @unknown default:
                state = .failed("macOS returned an unknown helper service status")
                return .unknown
            }
        }

        state = .failed(
            "macOS accepted the helper registration but did not expose the service")
        return .persistentMissing
    }

    private func reregister(currentBuild: String) async {
        state = .registering
        do {
            try await unregisterWithTimeout()
        } catch where Self.isJobNotFoundError(error) {
            // A concurrent reset or user action already reached the state we
            // need. The callback was delivered, so it is safe to register.
        } catch {
            state = .failed("Could not update the helper: \(error.localizedDescription)")
            return
        }
        // ServiceManagement can transiently reject an immediate register even
        // after unregister's completion. Give its state a real turn, then use
        // the bounded retry/backoff in register().
        await sleep(.milliseconds(200))
        await register(
            currentBuild: currentBuild,
            recoverPayloadMismatch: false,
            adoptAlreadyRegisteredApproval: true)
    }

    /// The completion-handler API has failed to reply on some Service
    /// Management states. Bound it so the UI can never remain `.registering`
    /// forever, and guard the timeout/callback race against double resume.
    private func unregisterWithTimeout() async throws {
        let operationID = UUID()
        pendingUnregisterOperationID = operationID
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let gate = HelperRegistrationContinuationGate()
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + unregisterTimeout
                ) {
                    gate.run {
                        continuation.resume(
                            throwing: HelperRegistrationOperationError.unregisterTimedOut)
                    }
                }
                service.unregister { [weak self] error in
                    let completedBeforeTimeout = gate.run {
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                    let result = HelperLateUnregisterResult(error: error)
                    Task { @MainActor [weak self] in
                        self?.unregisterCallbackArrived(
                            operationID: operationID,
                            completedBeforeTimeout: completedBeforeTimeout,
                            result: result)
                    }
                }
            }
            if pendingUnregisterOperationID == operationID {
                pendingUnregisterOperationID = nil
            }
        } catch HelperRegistrationOperationError.unregisterTimedOut {
            // The Service Management operation is still live. Its late callback
            // owns clearing the pending ID and scheduling a safe recovery.
            throw HelperRegistrationOperationError.unregisterTimedOut
        } catch {
            if pendingUnregisterOperationID == operationID {
                pendingUnregisterOperationID = nil
            }
            throw error
        }
    }

    private func unregisterCallbackArrived(
        operationID: UUID,
        completedBeforeTimeout: Bool,
        result: HelperLateUnregisterResult
    ) {
        guard pendingUnregisterOperationID == operationID else { return }
        pendingUnregisterOperationID = nil
        guard !completedBeforeTimeout else { return }

        switch result {
        case .completed, .jobNotFound:
            needsLateUnregisterRecovery = true
            scheduleLateUnregisterRecoveryIfPossible()
        case .failed(let message):
            state = .failed("Could not finish updating the helper: \(message)")
        }
    }

    private func scheduleLateUnregisterRecoveryIfPossible() {
        guard needsLateUnregisterRecovery,
              !isPreparing,
              pendingUnregisterOperationID == nil else { return }
        needsLateUnregisterRecovery = false
        Task { @MainActor [weak self] in
            await self?.prepare()
        }
    }

    /// Apple only guarantees that re-registration is safe after the async
    /// unregister callback. Status alone can change before the old helper has
    /// been reaped, so a lost callback must not allow an overlapping retry.
    private func serviceStatusResolvingPendingUnregister() -> SMAppService.Status? {
        guard pendingUnregisterOperationID == nil else {
            state = .failed(
                "macOS did not finish the previous helper update; restart your Mac if this continues")
            return nil
        }
        return service.status
    }

    private static nonisolated func isJobNotFoundError(_ error: Error) -> Bool {
        let error = error as NSError
        let isServiceManagementDomain =
            error.domain == "SMAppServiceErrorDomain"
            || error.domain.localizedCaseInsensitiveContains("ServiceManagement")
            || error.domain.hasPrefix("kSMErrorDomain")
        return isServiceManagementDomain
            && (error.code == Int(kSMErrorJobNotFound)
            || error.code == Int(kSMErrorJobPlistNotFound))
    }

    private static nonisolated func isServiceManagementError(
        _ error: Error,
        code: Int
    ) -> Bool {
        let error = error as NSError
        let isServiceManagementDomain =
            error.domain == "SMAppServiceErrorDomain"
            || error.domain.localizedCaseInsensitiveContains("ServiceManagement")
            || error.domain.hasPrefix("kSMErrorDomain")
        return isServiceManagementDomain && error.code == code
    }

    private static nonisolated func isAlreadyRegisteredError(_ error: Error) -> Bool {
        isServiceManagementError(error, code: Int(kSMErrorAlreadyRegistered))
    }

    private static nonisolated func isLaunchDeniedError(_ error: Error) -> Bool {
        isServiceManagementError(error, code: Int(kSMErrorLaunchDeniedByUser))
    }

    private static nonisolated func isTransientRegistrationError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) {
            return true
        }
        if error.domain == "SMAppServiceErrorDomain", error.code == Int(EPERM) {
            return true
        }
        return isServiceManagementError(error, code: Int(kSMErrorInternalFailure))
            || isServiceManagementError(error, code: Int(kSMErrorServiceUnavailable))
            || isServiceManagementError(error, code: Int(kSMErrorAlreadyRegistered))
    }

    private func apply(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: state = .notRegistered
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notFound:
            state = .failed("macOS could not find the registered helper service")
        @unknown default: state = .failed("Unknown helper service status")
        }
    }

    private static let expectedBundleProgram =
        "Contents/Library/HelperTools/JuiceHelper"

    private static func activeHelperMatchesBundledHelper() async -> Bool {
        let bundledURL = Bundle.main.bundleURL
            .appendingPathComponent(expectedBundleProgram)
        guard let bundled = HelperExecutableFingerprint.sha256(at: bundledURL) else {
            return false
        }
        do {
            let (_, version) = try await HelperClient().handshake()
            return HelperExecutableFingerprint.fromHandshakeVersion(version) == bundled
        } catch {
            return false
        }
    }

    /// Validate the payload independently of Service Management. Only this
    /// explicit check is allowed to claim that the installed copy is missing
    /// its helper.
    static func bundledHelperValidationError(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> String? {
        let bundleURL = bundleURL.standardizedFileURL
        let plistURL = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(JuiceXPC.daemonPlistName)")
        guard FileManager.default.isReadableFile(atPath: plistURL.path) else {
            return "The bundled launch-daemon property list is missing."
        }
        guard let plist = NSDictionary(contentsOf: plistURL),
              let bundleProgram = plist["BundleProgram"] as? String,
              bundleProgram == expectedBundleProgram else {
            return "The bundled launch-daemon property list is invalid."
        }

        let helperURL = bundleURL.appendingPathComponent(bundleProgram)
            .standardizedFileURL
        let bundlePrefix = bundleURL.path.hasSuffix("/")
            ? bundleURL.path : bundleURL.path + "/"
        guard helperURL.path.hasPrefix(bundlePrefix),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return "The bundled helper executable is missing or invalid."
        }
        return nil
    }

    private static var currentAppBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "unknown"
        return "\(version)-\(build)"
    }

    private static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
    }

}

private enum HelperRegistrationReconciliation {
    case settled
    case persistentMissing
    case payloadMismatch
    case unknown
}

private enum HelperRegistrationOperationError: LocalizedError, Sendable {
    case unregisterTimedOut

    var errorDescription: String? {
        switch self {
        case .unregisterTimedOut:
            return "macOS did not finish unregistering the previous helper in time"
        }
    }
}

private enum HelperLateUnregisterResult: Sendable {
    case completed
    case jobNotFound
    case failed(String)

    nonisolated init(error: Error?) {
        guard let error else {
            self = .completed
            return
        }
        let nsError = error as NSError
        let isServiceManagementDomain =
            nsError.domain == "SMAppServiceErrorDomain"
            || nsError.domain.localizedCaseInsensitiveContains("ServiceManagement")
            || nsError.domain.hasPrefix("kSMErrorDomain")
        if isServiceManagementDomain
            && (nsError.code == Int(kSMErrorJobNotFound)
            || nsError.code == Int(kSMErrorJobPlistNotFound)) {
            self = .jobNotFound
        } else {
            self = .failed(error.localizedDescription)
        }
    }
}

private final class HelperRegistrationContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    @discardableResult
    func run(_ body: @Sendable () -> Void) -> Bool {
        lock.lock()
        let shouldRun = !completed
        completed = true
        lock.unlock()
        if shouldRun { body() }
        return shouldRun
    }
}
