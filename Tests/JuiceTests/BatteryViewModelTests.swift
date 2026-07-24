import Foundation
import Testing
@testable import Juice

@Suite("Battery view model")
struct BatteryViewModelTests {
    @MainActor
    @Test("Power-state changes refresh Low Power Mode")
    func powerStateChangesRefreshLowPowerMode() async {
        var isLowPowerModeEnabled = false
        let notificationCenter = NotificationCenter()
        let model = BatteryViewModel(
            lowPowerModeProvider: { isLowPowerModeEnabled },
            notificationCenter: notificationCenter)

        #expect(!model.isLowPowerModeEnabled)

        isLowPowerModeEnabled = true
        notificationCenter.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(model.isLowPowerModeEnabled)
    }
}
