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

    @MainActor
    @Test("Mac mini mode treats the missing battery as supported")
    func macMiniSkipsBatteryReader() {
        var readCount = 0
        let model = BatteryViewModel(
            isMacMini: true,
            batteryReader: {
                readCount += 1
                throw BatteryMonitorError.serviceNotFound
            })

        #expect(readCount == 0)
        #expect(model.reading == nil)
        #expect(model.lastError == nil)
    }
}
