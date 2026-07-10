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
    case notFound
    case failed(String)
}

/// Registers the bundled launch daemon, tracks approval, and re-registers it
/// after an app update so launchd never keeps serving an older helper payload.
@MainActor
final class HelperRegistrationController: NSObject, ObservableObject {
    static let shared = HelperRegistrationController()

    @Published private(set) var state: HelperRegistrationState = .checking
    /// Advances only when a user/recovery transition makes the helper newly
    /// usable, so views can retry data without looping on ordinary error checks.
    @Published private(set) var readyGeneration = 0

    private let service: SMAppService
    private let defaults: UserDefaults
    private let registeredBuildKey = "registered_helper_app_build"
    private var isPreparing = false

    init(
        service: SMAppService = .daemon(plistName: JuiceXPC.daemonPlistName),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
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
        guard Self.isInstalledInApplications else {
            state = .needsApplicationInstall
            return
        }
        let status = service.status
        let currentBuild = Self.currentAppBuild
        let registeredBuild = defaults.string(forKey: registeredBuildKey)

        switch status {
        case .notRegistered:
            await register(currentBuild: currentBuild, allowApprovalAdoption: true)
        case .enabled:
            if await activeHelperMatchesBundledHelper() {
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
            state = .notFound
        @unknown default:
            state = .failed("Unknown helper service status")
        }
    }

    /// Re-read approval state after returning from System Settings.
    func refresh() {
        guard !isPreparing else { return }
        let previousState = state
        guard Self.isInstalledInApplications else {
            state = .needsApplicationInstall
            return
        }
        apply(service.status)
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
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            do {
                try service.register()
                defaults.set(currentBuild, forKey: registeredBuildKey)
                apply(service.status)
                return
            } catch {
                lastError = error
                // A register call can report an already-registered race even
                // after installing the new payload. Only adopt an enabled job
                // after its running executable proves it matches our bundle.
                if service.status == .enabled,
                   await activeHelperMatchesBundledHelper() {
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
                if service.status == .notFound {
                    state = .notFound
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

    private func reregister(currentBuild: String) async {
        state = .registering
        do {
            try await unregister()
            // ServiceManagement can transiently reject an immediate register
            // even after unregister's completion. Give its state a real turn,
            // then use the bounded retry/backoff in register().
            try? await Task.sleep(for: .milliseconds(200))
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
        case .notFound: state = .notFound
        @unknown default: state = .failed("Unknown helper service status")
        }
    }

    private func activeHelperMatchesBundledHelper() async -> Bool {
        let bundledURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/HelperTools/JuiceHelper")
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
