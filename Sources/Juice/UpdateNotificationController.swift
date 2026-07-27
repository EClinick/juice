import Foundation
@preconcurrency import UserNotifications

private enum UpdateNotificationIdentifier {
    static let category = "JUICE_UPDATE_READY"
    static let installAction = "JUICE_UPDATE_INSTALL"
    static let laterAction = "JUICE_UPDATE_LATER"
    static let readyRequest = "juice.update.ready"
}

@MainActor
protocol UpdateNotificationControlling: AnyObject {
    var onInstallRequested: (() -> Void)? { get set }

    func reset()
    func showUpdateReady(version: String)
}

/// Presents the one-time system notification for an update that Sparkle has
/// already downloaded and prepared. The popover remains the durable fallback
/// when notification permission is denied or the banner is dismissed.
@MainActor
final class UpdateNotificationController: NSObject, UpdateNotificationControlling {
    private let center: UNUserNotificationCenter

    var onInstallRequested: (() -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()

        let installAction = UNNotificationAction(
            identifier: UpdateNotificationIdentifier.installAction,
            title: "Update & Relaunch",
            options: [.foreground]
        )
        let laterAction = UNNotificationAction(
            identifier: UpdateNotificationIdentifier.laterAction,
            title: "Later"
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UpdateNotificationIdentifier.category,
                actions: [installAction, laterAction],
                intentIdentifiers: []
            )
        ])
        center.delegate = self
    }

    func reset() {
        center.removePendingNotificationRequests(
            withIdentifiers: [UpdateNotificationIdentifier.readyRequest]
        )
        center.removeDeliveredNotifications(
            withIdentifiers: [UpdateNotificationIdentifier.readyRequest]
        )
    }

    func showUpdateReady(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Juice \(version) is ready"
        content.body = "Click to update and relaunch Juice."
        content.categoryIdentifier = UpdateNotificationIdentifier.category

        let request = UNNotificationRequest(
            identifier: UpdateNotificationIdentifier.readyRequest,
            content: content,
            trigger: nil
        )
        let center = center
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}

extension UpdateNotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UpdateNotificationIdentifier.installAction ||
            response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor [weak self] in
                self?.onInstallRequested?()
            }
        }
        completionHandler()
    }
}
