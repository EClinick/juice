import Foundation
import JuiceSmartChargingBridge
import Testing

private final class CompatibleOptimizedOverrideClient: NSObject {
    @objc(temporarilyEnableCharging:)
    func temporarilyEnableCharging(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        false
    }
}

private final class CompatibleLimitOverrideClient: NSObject {
    @objc(temporarilyDisableMCL:)
    func temporarilyDisableMCL(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        false
    }
}

private final class WrongReturnOverrideClient: NSObject {
    @objc(temporarilyEnableCharging:)
    func temporarilyEnableCharging(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Int {
        0
    }
}

private final class WrongArgumentOverrideClient: NSObject {
    @objc(temporarilyEnableCharging:)
    func temporarilyEnableCharging(_ value: Int) -> Bool {
        false
    }
}

private final class SuccessfulUIStateWithErrorClient: NSObject {
    @objc(smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:)
    func smartChargingUIState(
        _ state: UnsafeMutablePointer<UInt>?,
        chargeLimit: UnsafeMutablePointer<UInt>?,
        chargingOverrideAllowed: UnsafeMutablePointer<ObjCBool>?,
        withError error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        state?.pointee = 6
        chargeLimit?.pointee = 100
        chargingOverrideAllowed?.pointee = true
        error?.pointee = NSError(domain: "test", code: 1)
        return true
    }

    @objc(temporarilyEnableCharging:)
    func temporarilyEnableCharging(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        false
    }
}

private final class UnknownManualHoldLimitClient: NSObject {
    @objc(smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:)
    func smartChargingUIState(
        _ state: UnsafeMutablePointer<UInt>?,
        chargeLimit: UnsafeMutablePointer<UInt>?,
        chargingOverrideAllowed: UnsafeMutablePointer<ObjCBool>?,
        withError error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        state?.pointee = 14
        chargeLimit?.pointee = 75
        chargingOverrideAllowed?.pointee = false
        return true
    }

    @objc(getMCLLimitWithError:)
    func getMCLLimit(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> UInt8 {
        75
    }

    @objc(temporarilyDisableMCL:)
    func temporarilyDisableMCL(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        false
    }
}

private final class KnownManualHoldFallbackClient: NSObject {
    @objc(smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:)
    func smartChargingUIState(
        _ state: UnsafeMutablePointer<UInt>?,
        chargeLimit: UnsafeMutablePointer<UInt>?,
        chargingOverrideAllowed: UnsafeMutablePointer<ObjCBool>?,
        withError error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        state?.pointee = 14
        chargeLimit?.pointee = 90
        chargingOverrideAllowed?.pointee = false
        return true
    }

    @objc(temporarilyDisableMCL:)
    func temporarilyDisableMCL(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        false
    }
}

private final class UnsupportedMCLClient: NSObject {
    @objc(availableChargeLimitsWithError:)
    func availableChargeLimits(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> NSArray {
        []
    }
}

private final class UnavailableMCLClient: NSObject {
    @objc(availableChargeLimitsWithError:)
    func availableChargeLimits(
        _ error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> NSArray {
        error?.pointee = NSError(domain: "test", code: 2)
        return []
    }
}

@Suite("Smart-charging raw state resolver")
struct ChargeHoldResolverTests {
    @Test("Only Control Center's optimized-hold states are actionable", arguments: [
        6, 7, 8, 10, 11, 12
    ])
    func optimizedHold(rawState: Int) {
        #expect(JSCResolveChargeHoldKind(UInt(rawState), true).rawValue == 1)
    }

    @Test("Optimized holds require an explicit override allowance", arguments: [
        6, 7, 8, 10, 11, 12
    ])
    func optimizedHoldWithoutOverride(rawState: Int) {
        #expect(JSCResolveChargeHoldKind(UInt(rawState), false).rawValue == 0)
    }

    @Test("Reached manual charge-limit states resolve independently", arguments: [
        14, 15, 16
    ])
    func manualLimit(rawState: Int) {
        #expect(JSCResolveChargeHoldKind(UInt(rawState), false).rawValue == 2)
    }

    @Test("Unknown and non-hold states fail closed", arguments: [
        0, 1, 2, 3, 4, 5, 9, 13, 17, 63, 64, 999
    ])
    func unknown(rawState: Int) {
        #expect(JSCResolveChargeHoldKind(UInt(rawState), true).rawValue == 0)
    }

    @Test("Persistent and temporary manual-limit states require consistent values")
    func chargeLimitState() {
        #expect(JSCResolveChargeLimitState(0, 100).rawValue == 0)
        for limit in [80, 85, 90, 95] {
            #expect(JSCResolveChargeLimitState(1, limit).rawValue == 1)
        }
        #expect(JSCResolveChargeLimitState(3, 100).rawValue == 3)

        for (state, limit) in [
            (0, 80), (0, 90),
            (1, 75), (1, 100),
            (2, 90),
            (3, 80), (3, 95),
            (999, 100),
        ] {
            #expect(JSCResolveChargeLimitState(UInt(state), limit).rawValue == -1)
        }
    }

    @Test("Manual holds accept only macOS's known fixed limits")
    func manualHoldLimit() {
        for limit in [80, 85, 90, 95] {
            #expect(JSCResolveManualHoldLimit(limit) == limit)
        }
        for limit in [0, 75, 79, 100, 105] {
            #expect(JSCResolveManualHoldLimit(limit) == 0)
        }
    }

    @Test("Optimized charging accepts only the four macOS states")
    func optimizedChargingState() {
        for state in 0...3 {
            #expect(
                JSCResolveOptimizedChargingState(UInt(state)).rawValue
                    == state)
        }
        for state in [4, 5, 12, 63, 999] {
            #expect(
                JSCResolveOptimizedChargingState(UInt(state)).rawValue
                    == -1)
        }
    }

    @Test("Charge to Full capability requires the selected action's exact ABI")
    func chargeToFullActionCapability() {
        let optimized = JSCChargeHoldKind(rawValue: 1)!
        let limit = JSCChargeHoldKind(rawValue: 2)!
        let none = JSCChargeHoldKind(rawValue: 0)!

        let optimizedClient = CompatibleOptimizedOverrideClient()
        #expect(JSCChargeToFullActionIsAvailable(optimizedClient, optimized))
        #expect(!JSCChargeToFullActionIsAvailable(optimizedClient, limit))
        #expect(!JSCChargeToFullActionIsAvailable(optimizedClient, none))

        let limitClient = CompatibleLimitOverrideClient()
        #expect(JSCChargeToFullActionIsAvailable(limitClient, limit))
        #expect(!JSCChargeToFullActionIsAvailable(limitClient, optimized))

        #expect(!JSCChargeToFullActionIsAvailable(NSObject(), optimized))
        #expect(!JSCChargeToFullActionIsAvailable(
            WrongReturnOverrideClient(),
            optimized))
        #expect(!JSCChargeToFullActionIsAvailable(
            WrongArgumentOverrideClient(),
            optimized))
    }

    @Test("A UI-state success carrying an error fails closed")
    func uiStateErrorFailsClosed() {
        var kind = JSCChargeHoldKind(rawValue: 2)!
        var limit = 75
        var error: NSError?

        let succeeded = JSCCopyChargeHoldStatusForClient(
            SuccessfulUIStateWithErrorClient(),
            &kind,
            &limit,
            &error)

        #expect(!succeeded)
        #expect(kind.rawValue == 0)
        #expect(limit == 100)
        #expect(error != nil)
    }

    @Test("An unknown manual-hold percentage is not actionable")
    func unknownManualHoldLimitFailsClosed() {
        var kind = JSCChargeHoldKind(rawValue: 2)!
        var limit = 75
        var error: NSError?

        let succeeded = JSCCopyChargeHoldStatusForClient(
            UnknownManualHoldLimitClient(),
            &kind,
            &limit,
            &error)

        #expect(succeeded)
        #expect(kind.rawValue == 0)
        #expect(limit == 100)
        #expect(error == nil)
    }

    @Test("A known UI-state limit remains authoritative without a second getter")
    func knownManualHoldFallbackRemainsActionable() {
        var kind = JSCChargeHoldKind(rawValue: 0)!
        var limit = 100
        var error: NSError?

        let succeeded = JSCCopyChargeHoldStatusForClient(
            KnownManualHoldFallbackClient(),
            &kind,
            &limit,
            &error)

        #expect(succeeded)
        #expect(kind.rawValue == 2)
        #expect(limit == 90)
        #expect(error == nil)
    }

    @Test("Charge Limit support stays distinct from an unavailable service")
    func mclSupportAndServiceFailureStayDistinct() {
        var supported: ObjCBool = true
        var limit = 80
        var options = JSCChargeLimitOptions(rawValue: UInt.max)
        var state = JSCChargeLimitState(rawValue: 1)!
        var error: NSError?

        let succeeded = JSCCopyChargeLimitConfigurationForClient(
            UnsupportedMCLClient(),
            &supported,
            &limit,
            &options,
            &state,
            &error)

        #expect(succeeded)
        #expect(!supported.boolValue)
        #expect(limit == 100)
        #expect(options.rawValue == 0)
        #expect(state.rawValue == -1)
        #expect(error == nil)

        supported = true
        limit = 80
        options = JSCChargeLimitOptions(rawValue: UInt.max)
        state = JSCChargeLimitState(rawValue: 1)!
        error = nil

        let unavailable = JSCCopyChargeLimitConfigurationForClient(
            UnavailableMCLClient(),
            &supported,
            &limit,
            &options,
            &state,
            &error)

        #expect(!unavailable)
        #expect(!supported.boolValue)
        #expect(limit == 100)
        #expect(options.rawValue == 0)
        #expect(state.rawValue == -1)
        #expect(error != nil)
    }

    @Test("Available Charge Limit choices reject malformed payloads as a whole")
    func availableChargeLimits() {
        let all = JSCResolveAvailableChargeLimits([80, 85, 90, 95, 100])
        #expect(all.rawValue == 0b1_1111)

        let subset = JSCResolveAvailableChargeLimits([80, 90, 100])
        #expect(subset.rawValue == 0b1_0101)

        let malformed: [[Any]] = [
            [],
            [80, "90", 100],
            [80, 90.5, 100],
            [80, 80, 100],
            [75, 80, 100],
            [80, 105],
        ]
        for payload in malformed {
            #expect(JSCResolveAvailableChargeLimits(payload).rawValue == 0)
        }
    }
}
