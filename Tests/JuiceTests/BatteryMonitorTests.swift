import Foundation
import Testing
@testable import Juice

@Suite("Battery monitor")
struct BatteryMonitorTests {
    @Test("reads whole-system load from power telemetry")
    func readsSystemLoad() {
        let properties: [String: Any] = [
            "PowerTelemetryData": [
                "SystemLoad": NSNumber(value: 24_055)
            ]
        ]

        #expect(BatteryMonitor.systemLoadWatts(from: properties) == 24.055)
    }

    @Test("leaves system load unavailable when telemetry is absent")
    func missingSystemLoad() {
        #expect(BatteryMonitor.systemLoadWatts(from: [:]) == nil)
    }
}
