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

    @Test("A reached manual charge limit resolves independently")
    func manualLimit() {
        #expect(JSCResolveChargeHoldKind(13, false).rawValue == 2)
    }

    @Test("Unknown and non-hold states fail closed", arguments: [
        0, 1, 2, 3, 4, 5, 9, 14, 63, 64, 999
    ])
    func unknown(rawState: Int) {
        #expect(JSCResolveChargeHoldKind(UInt(rawState), true).rawValue == 0)
    }
}
