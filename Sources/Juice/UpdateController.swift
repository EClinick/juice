import Combine
import Foundation
import Sparkle

struct ReadyUpdate: Equatable {
    let version: String
}

/// Owns the Sparkle updater and exposes the two update modes Juice supports:
/// scheduled, automatic updates and user-initiated checks.
///
/// The controller is intentionally unavailable in development builds and in
/// release candidates that have not been configured with Juice's Sparkle public
/// key. This prevents an unsigned or misconfigured feed from ever being used.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let updaterDelegate: UpdaterDelegate
    private var updaterController: SPUStandardUpdaterController?
    private let updateNotifications: UpdateNotificationControlling
    private var installReadyUpdateHandler: (() -> Void)?

    /// Whether this bundle has a signed update feed configured.
    let isAvailable: Bool

    /// The update Sparkle has downloaded and prepared for installation.
    @Published private(set) var readyUpdate: ReadyUpdate?

    /// When enabled, Sparkle checks for updates on its normal schedule,
    /// downloads them, and prepares them for an explicit or quit-time install.
    /// When disabled, users can still use ``checkForUpdates()`` manually.
    var automaticallyUpdates: Bool {
        get {
            guard let updater = updaterController?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            guard let updater = updaterController?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    init(
        bundle: Bundle = .main,
        updateNotifications: UpdateNotificationControlling? = nil
    ) {
        let updaterDelegate = UpdaterDelegate()
        let updateNotifications =
            updateNotifications ?? UpdateNotificationController()
        self.updaterDelegate = updaterDelegate
        self.updateNotifications = updateNotifications
        updaterController = nil
        isAvailable = Self.hasSignedFeedConfiguration(in: bundle)

        updateNotifications.reset()
        updateNotifications.onInstallRequested = { [weak self] in
            self?.installReadyUpdate()
        }

        guard isAvailable else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        updaterDelegate.controller = self
        controller.startUpdater()
        updaterController = controller
    }

    /// Presents Sparkle's standard update flow, including the no-update state.
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// Installs the prepared update and asks Sparkle to relaunch Juice.
    func installReadyUpdate() {
        installReadyUpdateHandler?()
    }

    func handleReadyUpdate(
        version: String,
        installHandler: @escaping () -> Void
    ) {
        let shouldNotify = readyUpdate?.version != version
        readyUpdate = ReadyUpdate(version: version)
        installReadyUpdateHandler = installHandler

        if shouldNotify {
            updateNotifications.showUpdateReady(version: version)
        }
    }

    private static func hasSignedFeedConfiguration(in bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension == "app",
              let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feedURL),
              url.scheme == "https",
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let publicKeyData = Data(base64Encoded: publicKey),
              publicKeyData.count == 32
        else {
            return false
        }

        return true
    }
}

/// Update checks need a network request, but never include a system profile or
/// any Juice usage data.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdateController?

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler:
            @escaping () -> Void
    ) -> Bool {
        guard let controller else { return false }

        controller.handleReadyUpdate(
            version: item.displayVersionString,
            installHandler: immediateInstallHandler
        )
        return true
    }
}
