import JuiceSmartChargingBridge
import Testing

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
