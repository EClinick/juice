import Foundation
import Sparkle

/// Owns the Sparkle updater and exposes the two update modes Juice supports:
/// scheduled, automatic updates and user-initiated checks.
///
/// The controller is intentionally unavailable in development builds and in
/// release candidates that have not been configured with Juice's Sparkle public
/// key. This prevents an unsigned or misconfigured feed from ever being used.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let updaterDelegate = UpdaterDelegate()
    private let updaterController: SPUStandardUpdaterController?

    /// Whether this bundle has a signed update feed configured.
    let isAvailable: Bool

    /// When enabled, Sparkle checks for updates on its normal schedule and
    /// downloads and installs them automatically. When disabled, users can
    /// still use ``checkForUpdates()`` to update manually.
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

    private init(bundle: Bundle = .main) {
        guard Self.hasSignedFeedConfiguration(in: bundle) else {
            updaterController = nil
            isAvailable = false
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        controller.startUpdater()
        updaterController = controller
        isAvailable = true
    }

    /// Presents Sparkle's standard update flow, including the no-update state.
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
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
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }
}
