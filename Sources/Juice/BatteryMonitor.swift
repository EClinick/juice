import Foundation
import IOKit

/// A single snapshot of the battery state, read from IOKit's AppleSmartBattery service.
struct BatteryReading {
    var percent: Int
    var watts: Double          // positive = discharging, negative = charging
    var isCharging: Bool
    var onAC: Bool
    var timeRemainingMinutes: Int?   // nil while macOS is still estimating
    var cycleCount: Int
    var healthPercent: Int?          // current max capacity vs design capacity
    var hasBattery: Bool
}

enum BatteryMonitorError: Error {
    case serviceNotFound
    case propertiesUnreadable
}

/// Reads battery state from the AppleSmartBattery IORegistry service.
/// No special permissions required.
struct BatteryMonitor {
    static func read() throws -> BatteryReading {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { throw BatteryMonitorError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            throw BatteryMonitorError.propertiesUnreadable
        }

        func int(_ key: String) -> Int? { props[key] as? Int }
        func signedInt64(_ key: String) -> Int64? { (props[key] as? NSNumber)?.int64Value }
        func bool(_ key: String) -> Bool { props[key] as? Bool ?? false }

        let installed = bool("BatteryInstalled")

        // Require the core fields; don't fabricate readings from missing data.
        guard let current = int("CurrentCapacity"),
              let max = int("MaxCapacity"), max > 0,
              let rawVoltage = int("Voltage"),
              let rawAmperage = signedInt64("Amperage") else {
            throw BatteryMonitorError.propertiesUnreadable
        }
        let percent = Int((Double(current) / Double(max) * 100).rounded())

        // Amperage is in mA (negative while discharging), Voltage in mV.
        // IOKit can publish Amperage as a wrapped UInt64; NSNumber.int64Value
        // reinterprets the low 64 bits as a signed value correctly.
        let amperage = Double(rawAmperage)
        let voltage = Double(rawVoltage)
        let watts = -(amperage / 1000.0) * (voltage / 1000.0)

        // 65535 means "still calculating".
        let rawMinutes = int("TimeRemaining") ?? 0
        let timeRemaining = (rawMinutes > 0 && rawMinutes < 65535) ? rawMinutes : nil

        var health: Int? = nil
        if let design = int("DesignCapacity"), design > 0,
           let rawMax = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") {
            health = Int((Double(rawMax) / Double(design) * 100).rounded())
        }

        return BatteryReading(
            percent: percent,
            watts: watts,
            isCharging: bool("IsCharging"),
            onAC: bool("ExternalConnected"),
            timeRemainingMinutes: timeRemaining,
            cycleCount: int("CycleCount") ?? 0,
            healthPercent: health,
            hasBattery: installed
        )
    }
}
