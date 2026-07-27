import Foundation
import Testing
@testable import Juice

@Suite("Update controller")
@MainActor
struct UpdateControllerTests {
    @Test("Prepared updates remain visible and install on request")
    func preparedUpdateInstallsOnRequest() {
        let notifications = TestUpdateNotifications()
        let controller = UpdateController(
            bundle: .main,
            updateNotifications: notifications
        )
        var installCount = 0

        controller.handleReadyUpdate(version: "0.2.4") {
            installCount += 1
        }

        #expect(controller.readyUpdate == ReadyUpdate(version: "0.2.4"))
        #expect(notifications.shownVersions == ["0.2.4"])

        notifications.onInstallRequested?()

        #expect(installCount == 1)
    }

    @Test("Repeated callbacks do not duplicate the notification")
    func repeatedReadyCallbackDoesNotRenotify() {
        let notifications = TestUpdateNotifications()
        let controller = UpdateController(
            bundle: .main,
            updateNotifications: notifications
        )

        controller.handleReadyUpdate(version: "0.2.4") {}
        controller.handleReadyUpdate(version: "0.2.4") {}

        #expect(notifications.shownVersions == ["0.2.4"])
    }
}

@MainActor
private final class TestUpdateNotifications: UpdateNotificationControlling {
    var onInstallRequested: (() -> Void)?
    private(set) var shownVersions: [String] = []

    func reset() {}

    func showUpdateReady(version: String) {
        shownVersions.append(version)
    }
}
