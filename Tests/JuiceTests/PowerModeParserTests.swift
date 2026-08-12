import Foundation
import Testing
@testable import JuiceXPCShared

@Suite("Power mode parser")
struct PowerModeParserTests {
    /// Verbatim `pmset -g custom` output from a Mac17,8 (both sections carry
    /// `powermode`), including the four-field "Sleep On Power Button" line.
    static let modernOutput = """
    Battery Power:
     Sleep On Power Button 1
     powermode            1
     standby              1
     hibernatemode        3
     displaysleep         2
     lessbright           1
    AC Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     hibernatemode        3
     displaysleep         10
    """

    /// The oldest layout: a 0/1 `lowpowermode` key and no `highpowermode`, so
    /// the machine has no High Power at all.
    static let lowPowerOnlyOutput = """
    Battery Power:
     lowpowermode         1
     displaysleep         2
    AC Power:
     lowpowermode         0
     displaysleep         10
    """

    /// The dual-boolean layout documented in pmset(1) SETTINGS: separate
    /// `lowpowermode` and `highpowermode` keys, both 0/1, and no `powermode`.
    /// Battery is in Low Power, AC in High Power.
    static let dualBooleanOutput = """
    Battery Power:
     lowpowermode         1
     highpowermode        0
     displaysleep         2
    AC Power:
     lowpowermode         0
     highpowermode        1
     displaysleep         10
    """

    @Test("Parses powermode from both sections")
    func parsesModernOutput() throws {
        let state = try PowerModeParser.parse(pmsetCustomOutput: Self.modernOutput)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, keyLayout: .unified))
        #expect(state.keyLayout == .unified)
        #expect(!state.usesLegacyLowPowerKey)
    }

    @Test("Parses a lowpowermode-only machine and records that it has no High Power")
    func parsesLowPowerOnlyOutput() throws {
        let state = try PowerModeParser.parse(pmsetCustomOutput: Self.lowPowerOnlyOutput)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, keyLayout: .lowPowerOnly))
        #expect(state.usesLegacyLowPowerKey)
    }

    @Test("Combines the dual-boolean keys into a mode per source")
    func parsesDualBooleanOutput() throws {
        let state = try PowerModeParser.parse(pmsetCustomOutput: Self.dualBooleanOutput)
        // An active highpowermode used to read as Automatic and hide the option
        // on hardware that supports it.
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .highPower, keyLayout: .dualBoolean))
        // The layout is not the legacy one, so High Power stays on offer.
        #expect(!state.usesLegacyLowPowerKey)
    }

    @Test("Both dual booleans clear means Automatic")
    func parsesDualBooleanAutomatic() throws {
        let output = """
        Battery Power:
         lowpowermode         0
         highpowermode        0
        AC Power:
         lowpowermode         0
         highpowermode        0
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .automatic, ac: .automatic, keyLayout: .dualBoolean))
    }

    @Test("Both dual booleans set reads as High Power, the more specific state")
    func dualBooleanConflictPrefersHighPower() throws {
        let output = """
        Battery Power:
         lowpowermode         1
         highpowermode        1
        AC Power:
         lowpowermode         1
         highpowermode        1
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .highPower, ac: .highPower, keyLayout: .dualBoolean))
    }

    @Test("A highpowermode key in either section makes the whole machine dual-boolean")
    func dualBooleanDetectedFromOneSection() throws {
        // The key layout is a hardware property: a section that only mentions
        // lowpowermode must not downgrade a machine that has High Power.
        let output = """
        Battery Power:
         lowpowermode         0
         highpowermode        1
        AC Power:
         lowpowermode         1
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .highPower, ac: .lowPower, keyLayout: .dualBoolean))
    }

    @Test("Mirrors a lone dual-boolean section onto the missing source")
    func mirrorsDualBooleanSection() throws {
        let output = """
        AC Power:
         lowpowermode         0
         highpowermode        1
         displaysleep         10
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .highPower, ac: .highPower, keyLayout: .dualBoolean,
            hasBatterySource: false))
    }

    @Test("Throws rather than guessing at a boolean key that is not 0 or 1")
    func throwsOnNonBooleanFlag() {
        let output = """
        Battery Power:
         lowpowermode         0
         highpowermode        7
        AC Power:
         lowpowermode         0
         highpowermode        0
        """
        #expect(throws: PowerModeParser.ParseError.unrecognizedValue(
            section: "Battery Power:", value: "7")) {
            try PowerModeParser.parse(pmsetCustomOutput: output)
        }
    }

    @Test("Parses high power")
    func parsesHighPower() throws {
        let output = Self.modernOutput.replacingOccurrences(
            of: "powermode            0", with: "powermode            2")
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state.ac == .highPower)
    }

    @Test("Tolerates junk lines, blank lines, and CRLF-ish whitespace")
    func toleratesJunk() throws {
        let output = """

        some preamble nobody documented
        \tBattery Power:\u{20}
         garbage
         powermode            2
         womp                 0
        AC Power:
         a b c d e
         powermode            2
        trailing noise
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .highPower, ac: .highPower, keyLayout: .unified))
    }

    @Test("Attributes a key strictly to the section header above it")
    func attributesKeysToSections() throws {
        let output = """
        AC Power:
         powermode            2
        Battery Power:
         powermode            1
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state.ac == .highPower)
        #expect(state.battery == .lowPower)
    }

    @Test("Throws when no section is present")
    func throwsWithoutSections() {
        #expect(throws: PowerModeParser.ParseError.missingSections) {
            try PowerModeParser.parse(pmsetCustomOutput: "powermode 1\nnothing useful here\n")
        }
    }

    /// Verbatim shape of `pmset -g custom` on a desktop: no battery, so no
    /// "Battery Power:" section at all.
    static let acOnlyOutput = """
    AC Power:
     Sleep On Power Button 1
     powermode            2
     displaysleep         10
    """

    @Test("Mirrors the only section present on an AC-only Mac")
    func parsesACOnlyOutput() throws {
        let state = try PowerModeParser.parse(pmsetCustomOutput: Self.acOnlyOutput)
        #expect(state.ac == .highPower)
        #expect(state.battery == .highPower)
        #expect(!state.hasBatterySource)
        #expect(state.mode(for: .all) == .highPower)
    }

    @Test("Mirrors a lone Battery Power section too")
    func parsesBatteryOnlyOutput() throws {
        let output = """
        Battery Power:
         powermode            1
         displaysleep         2
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .lowPower, keyLayout: .unified))
        #expect(state.hasBatterySource)
    }

    @Test("Full output records that a battery source exists")
    func recordsBatterySource() throws {
        #expect(try PowerModeParser.parse(pmsetCustomOutput: Self.modernOutput).hasBatterySource)
    }

    @Test("Throws when neither section carries a power mode key")
    func throwsWithoutKey() {
        let output = """
        Battery Power:
         displaysleep         2
        AC Power:
         displaysleep         10
        """
        #expect(throws: PowerModeParser.ParseError.missingPowerModeKey(section: "Battery Power:")) {
            try PowerModeParser.parse(pmsetCustomOutput: output)
        }
    }

    @Test("A present battery section with no mode key is an error, not a mirror")
    func keylessBatterySectionThrows() {
        // Mirroring AC here would publish "Low Power on battery" for a machine
        // that never said so, and hide that the output was not understood.
        let output = """
        Battery Power:
         displaysleep         2
        AC Power:
         powermode            1
         displaysleep         10
        """
        #expect(throws: PowerModeParser.ParseError.missingPowerModeKey(section: "Battery Power:")) {
            try PowerModeParser.parse(pmsetCustomOutput: output)
        }
    }

    @Test("A present AC section with no mode key is an error, not a mirror")
    func keylessACSectionThrows() {
        let output = """
        Battery Power:
         powermode            1
        AC Power:
         displaysleep         10
        """
        #expect(throws: PowerModeParser.ParseError.missingPowerModeKey(section: "AC Power:")) {
            try PowerModeParser.parse(pmsetCustomOutput: output)
        }
    }

    @Test("Ignores keys under a section header this build does not know")
    func ignoresUnknownSections() throws {
        let output = """
        Battery Power:
         powermode            1
        UPS Power:
         powermode            2
        AC Power:
         powermode            0
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        // The UPS mode must not be attributed to the battery above it.
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, keyLayout: .unified))
    }

    @Test("An unknown trailing section cannot supply a missing source")
    func unknownSectionCannotStandInForBattery() {
        let output = """
        UPS Power:
         powermode            2
        """
        #expect(throws: PowerModeParser.ParseError.missingSections) {
            try PowerModeParser.parse(pmsetCustomOutput: output)
        }
    }

    @Test("Prefers powermode over the booleans whichever comes first", arguments: [true, false])
    func prefersModernKey(legacyFirst: Bool) throws {
        let modern = " powermode            2"
        let legacy = " lowpowermode         1"
        let keys = legacyFirst ? [legacy, modern] : [modern, legacy]
        let output = (["Battery Power:"] + keys + ["AC Power:"] + keys).joined(separator: "\n")

        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .highPower, ac: .highPower, keyLayout: .unified))
    }

    @Test("Throws rather than guessing at an unknown mode value")
    func throwsOnUnknownValue() {
        let output = """
        Battery Power:
         powermode            7
        AC Power:
         powermode            0
        """
        #expect(throws: PowerModeParser.ParseError.unrecognizedValue(
            section: "Battery Power:", value: "7")) {
            try PowerModeParser.parse(pmsetCustomOutput: output)
        }
    }

    @Test("Scopes map to pmset selector flags")
    func scopeFlags() {
        #expect(PowerModeScope.battery.pmsetFlag == "-b")
        #expect(PowerModeScope.ac.pmsetFlag == "-c")
        #expect(PowerModeScope.all.pmsetFlag == "-a")
    }

    @Test("Mode lookup treats .all as defined only when both sources agree")
    func modeForScope() {
        let mixed = PowerModeState(battery: .lowPower, ac: .automatic, keyLayout: .unified)
        #expect(mixed.mode(for: .battery) == .lowPower)
        #expect(mixed.mode(for: .ac) == .automatic)
        #expect(mixed.mode(for: .all) == nil)

        let agreed = PowerModeState(battery: .highPower, ac: .highPower, keyLayout: .unified)
        #expect(agreed.mode(for: .all) == .highPower)
    }

    @Test("powermode also outranks highpowermode inside a section")
    func prefersUnifiedKeyOverHighPowerFlag() throws {
        let output = """
        Battery Power:
         powermode            1
         highpowermode        1
        AC Power:
         powermode            1
         highpowermode        1
        """
        let state = try PowerModeParser.parse(pmsetCustomOutput: output)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .lowPower, keyLayout: .unified))
    }

    @Test("Round-trips every key layout through JSON, the XPC payload encoding",
          arguments: [PowerModeKeyLayout.unified, .dualBoolean, .lowPowerOnly])
    func roundTripsJSON(layout: PowerModeKeyLayout) throws {
        let state = PowerModeState(
            battery: .highPower, ac: .automatic, keyLayout: layout,
            hasBatterySource: false)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(PowerModeState.self, from: data) == state)
    }

    @Test("Still publishes the retired boolean for a peer that predates the layout")
    func encodesLegacyCompatibilityFlag() throws {
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(PowerModeState(
                battery: .automatic, ac: .automatic, keyLayout: .lowPowerOnly)))
        let fields = try #require(encoded as? [String: Any])
        #expect(fields["keyLayout"] as? String == "lowPowerOnly")
        #expect(fields["usesLegacyLowPowerKey"] as? Bool == true)
    }

    @Test("Decodes a payload from a helper that predates keyLayout",
          arguments: [(false, PowerModeKeyLayout.unified), (true, .lowPowerOnly)])
    func decodesPayloadWithoutKeyLayout(legacy: Bool, expected: PowerModeKeyLayout) throws {
        // The older boolean only distinguished these two layouts; a helper that
        // cannot say more must still decode rather than fail the write.
        let json = Data(#"{"battery":1,"ac":0,"usesLegacyLowPowerKey":\#(legacy)}"#.utf8)
        let state = try JSONDecoder().decode(PowerModeState.self, from: json)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, keyLayout: expected))
    }

    @Test("Decodes a payload carrying neither the layout nor the retired boolean")
    func decodesPayloadWithoutEitherKey() throws {
        let json = Data(#"{"battery":2,"ac":2}"#.utf8)
        let state = try JSONDecoder().decode(PowerModeState.self, from: json)
        #expect(state == PowerModeState(
            battery: .highPower, ac: .highPower, keyLayout: .unified))
    }

    @Test("Decodes a payload from a helper that predates hasBatterySource")
    func decodesLegacyPayload() throws {
        let json = Data(#"{"battery":1,"ac":0,"usesLegacyLowPowerKey":false}"#.utf8)
        let state = try JSONDecoder().decode(PowerModeState.self, from: json)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, keyLayout: .unified))
        #expect(state.hasBatterySource)
    }
}
