import Testing
@testable import Juice

@Suite("Mac hardware detection")
struct MacHardwareTests {
    @Test("Recognizes modern Mac mini product names with generic model IDs")
    func modernMacMini() {
        #expect(MacHardware.isMacMini(
            productName: "Mac mini (2024)",
            modelIdentifier: "Mac16,10"))
    }

    @Test("Recognizes legacy Mac mini model identifiers")
    func legacyMacMini() {
        #expect(MacHardware.isMacMini(
            productName: nil,
            modelIdentifier: "Macmini9,1"))
    }

    @Test("Uses the compatible fallback published by newer device trees")
    func fallbackIdentifier() {
        #expect(MacHardware.isMacMini(
            productName: nil,
            modelIdentifier: "Mac16,10",
            fallbackIdentifier: "Macmini9,1"))
    }

    @Test("Does not classify portable or desktop Macs as Mac minis")
    func otherMacs() {
        #expect(!MacHardware.isMacMini(
            productName: "MacBook Pro (16-inch, 2024)",
            modelIdentifier: "Mac16,5"))
        #expect(!MacHardware.isMacMini(
            productName: "Mac Studio (2025)",
            modelIdentifier: "Mac15,14"))
    }
}
