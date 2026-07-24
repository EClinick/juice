import AppKit
import Testing
@testable import Juice

@Suite("Battery status icon")
struct BatteryStatusIconTests {
    @Test("Low Power Mode uses a colored icon")
    func lowPowerModeUsesColoredIcon() {
        #expect(BatteryStatusIcon.fillStyle(
            percent: 75,
            onAC: false,
            isLowPowerModeEnabled: true) == .lowPower)

        let image = BatteryStatusIcon.image(
            percent: 75,
            isCharging: false,
            onAC: false,
            isLowPowerModeEnabled: true)

        #expect(!image.isTemplate)
    }

    @Test("Normal battery state remains a template icon")
    func normalStateUsesTemplateIcon() {
        let image = BatteryStatusIcon.image(
            percent: 75,
            isCharging: false,
            onAC: false,
            isLowPowerModeEnabled: false)

        #expect(image.isTemplate)
    }

    @Test("Critical battery warning takes priority over Low Power Mode")
    func criticalBatteryTakesPriority() {
        #expect(BatteryStatusIcon.fillStyle(
            percent: 10,
            onAC: false,
            isLowPowerModeEnabled: true) == .lowBattery)
    }
}
