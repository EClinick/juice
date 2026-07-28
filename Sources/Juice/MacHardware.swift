import Foundation
import IOKit

/// Identifies Mac hardware features that change which Juice experience makes
/// sense. Newer Apple silicon Macs use generic model identifiers such as
/// `Mac16,10`, so form-factor detection must prefer the device-tree product
/// name instead of relying only on the historical `Macmini…` prefix.
enum MacHardware {
    static let isCurrentMacMini: Bool = {
        isMacMini(
            productName: registryString(
                path: "IODeviceTree:/product",
                key: "product-name"),
            modelIdentifier: registryString(
                matchingService: "IOPlatformExpertDevice",
                key: "model"),
            fallbackIdentifier: registryString(
                path: "IODeviceTree:/product",
                key: "compatible-device-fallback")
        )
    }()

    /// Pure classification kept separate from IOKit so both old and new model
    /// naming schemes can be covered deterministically in tests.
    static func isMacMini(
        productName: String?,
        modelIdentifier: String?,
        fallbackIdentifier: String? = nil
    ) -> Bool {
        [productName, modelIdentifier, fallbackIdentifier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { value in
                value.localizedCaseInsensitiveContains("Mac mini")
                    || value.lowercased().hasPrefix("macmini")
            }
    }

    private static func registryString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return stringProperty(key, from: entry)
    }

    private static func registryString(matchingService: String, key: String) -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(matchingService)
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return stringProperty(key, from: service)
    }

    private static func stringProperty(_ key: String, from entry: io_registry_entry_t) -> String? {
        guard let property = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        if let value = property as? String {
            return value
        }
        if let data = property as? Data {
            let bytes = data.prefix { $0 != 0 }
            return String(data: bytes, encoding: .utf8)
        }
        return nil
    }
}
