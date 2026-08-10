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

    /// Older machines expose a 0/1 `lowpowermode` key instead.
    static let legacyOutput = """
    Battery Power:
     lowpowermode         1
     displaysleep         2
    AC Power:
     lowpowermode         0
     displaysleep         10
    """

    @Test("Parses powermode from both sections")
    func parsesModernOutput() throws {
        let state = try PowerModeParser.parse(pmsetCustomOutput: Self.modernOutput)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: false))
        #expect(state.pmsetKey == "powermode")
    }

    @Test("Parses the legacy lowpowermode key and flags the machine")
    func parsesLegacyOutput() throws {
        let state = try PowerModeParser.parse(pmsetCustomOutput: Self.legacyOutput)
        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: true))
        #expect(state.pmsetKey == "lowpowermode")
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
            battery: .highPower, ac: .highPower, usesLegacyLowPowerKey: false))
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

    @Test("Throws when a section carries no power mode key")
    func throwsWithoutKey() {
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
        let mixed = PowerModeState(battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: false)
        #expect(mixed.mode(for: .battery) == .lowPower)
        #expect(mixed.mode(for: .ac) == .automatic)
        #expect(mixed.mode(for: .all) == nil)

        let agreed = PowerModeState(battery: .highPower, ac: .highPower, usesLegacyLowPowerKey: false)
        #expect(agreed.mode(for: .all) == .highPower)
    }

    @Test("Round-trips through JSON, the XPC payload encoding")
    func roundTripsJSON() throws {
        let state = PowerModeState(battery: .highPower, ac: .automatic, usesLegacyLowPowerKey: false)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(PowerModeState.self, from: data) == state)
    }
}
