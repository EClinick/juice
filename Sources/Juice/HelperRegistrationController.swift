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
    private let registeredBuildKey = "registered_helper_app_build"
    private var isPreparing = false

    init(
        service: HelperServiceManaging = SMAppService.daemon(
            plistName: JuiceXPC.daemonPlistName),
        defaults: UserDefaults = .standard,
        installedInApplications: (() -> Bool)? = nil,
        payloadValidationError: (() -> String?)? = nil,
        helperMatchesBundledPayload: (() async -> Bool)? = nil,
        sleep: ((Duration) async -> Void)? = nil
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
        let status = service.status
        let currentBuild = Self.currentAppBuild
        let registeredBuild = defaults.string(forKey: registeredBuildKey)

        switch status {
        case .notRegistered:
            await register(currentBuild: currentBuild, allowApprovalAdoption: true)
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
            await recoverMissingRegistration(currentBuild: currentBuild)
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
        let status = service.status
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

    private func register(currentBuild: String, allowApprovalAdoption: Bool) async {
        state = .registering
        var lastError: Error?
        let retryDelays: [Duration] = [.zero, .milliseconds(150), .milliseconds(500)]

        for (attempt, delay) in retryDelays.enumerated() {
            if delay != .zero { await sleep(delay) }
            do {
                try service.register()
                await reconcileRegisteredStatus(currentBuild: currentBuild)
                return
            } catch {
                lastError = error
                // A register call can report an already-registered race even
                // after installing the new payload. Only adopt an enabled job
                // after its running executable proves it matches our bundle.
                if service.status == .enabled,
                   await helperMatchesBundledPayload() {
                    defaults.set(currentBuild, forKey: registeredBuildKey)
                    apply(service.status)
                    return
                }
                if service.status == .requiresApproval {
                    if allowApprovalAdoption {
                        // This path began at .notRegistered, so there is no
                        // older job that could be confused with this attempt.
                        defaults.set(currentBuild, forKey: registeredBuildKey)
                    }
                    state = .requiresApproval
                    return
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

    /// A never-registered daemon and a daemon whose Background Task Management
    /// record was reset can both report `.notFound`. Clear any stale record on
    /// a best-effort basis, then perform the real registration.
    private func recoverMissingRegistration(currentBuild: String) async {
        state = .registering
        try? await unregister()
        await sleep(.milliseconds(200))
        await register(currentBuild: currentBuild, allowApprovalAdoption: false)
    }

    /// Service Management may lag briefly after accepting registration. Avoid
    /// turning one intermediate `.notFound` sample into a permanent failure.
    private func reconcileRegisteredStatus(currentBuild: String) async {
        let retryDelays: [Duration] = [
            .zero, .milliseconds(150), .milliseconds(500), .seconds(1)
        ]

        for delay in retryDelays {
            if delay != .zero { await sleep(delay) }
            let status = service.status
            switch status {
            case .enabled:
                guard await helperMatchesBundledPayload() else {
                    continue
                }
                defaults.set(currentBuild, forKey: registeredBuildKey)
                state = .enabled
                return
            case .requiresApproval:
                defaults.set(currentBuild, forKey: registeredBuildKey)
                state = .requiresApproval
                return
            case .notRegistered, .notFound:
                continue
            @unknown default:
                state = .failed("macOS returned an unknown helper service status")
                return
            }
        }

        state = .failed(
            "macOS accepted the helper registration but did not expose the service")
    }

    private func reregister(currentBuild: String) async {
        state = .registering
        do {
            try await unregister()
            // ServiceManagement can transiently reject an immediate register
            // even after unregister's completion. Give its state a real turn,
            // then use the bounded retry/backoff in register().
            await sleep(.milliseconds(200))
            await register(currentBuild: currentBuild, allowApprovalAdoption: false)
        } catch {
            state = .failed("Could not update the helper: \(error.localizedDescription)")
        }
    }

    private func unregister() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
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

    private static func isTransientRegistrationError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) {
            return true
        }
        if error.domain == "SMAppServiceErrorDomain", error.code == Int(EPERM) {
            return true
        }
        let isServiceManagementDomain =
            error.domain == "SMAppServiceErrorDomain"
            || error.domain.localizedCaseInsensitiveContains("ServiceManagement")
            || error.domain.hasPrefix("kSMErrorDomain")
        return isServiceManagementDomain
            && (error.code == Int(kSMErrorInternalFailure)
            || error.code == Int(kSMErrorServiceUnavailable)
            || error.code == Int(kSMErrorAlreadyRegistered))
    }
}
