import Foundation

/// macOS Energy Mode, as exposed by `pmset`'s `powermode` key.
public enum PowerMode: Int, Codable, Sendable {
    case automatic = 0
    case lowPower = 1
    case highPower = 2
}

/// Which `pmset` power source a write applies to.
public enum PowerModeScope: String, Codable, Sendable {
    case battery
    case ac
    case all

    /// The `pmset` selector flag for this scope.
    public var pmsetFlag: String {
        switch self {
        case .battery: return "-b"
        case .ac: return "-c"
        case .all: return "-a"
        }
    }
}

/// The Energy Mode currently configured for each power source.
public struct PowerModeState: Codable, Sendable, Equatable {
    public var battery: PowerMode
    public var ac: PowerMode
    /// True when `pmset` exposes the older `lowpowermode` key instead of
    /// `powermode`. Those machines only accept 0/1, so High Power is
    /// unreachable and must never be offered.
    public var usesLegacyLowPowerKey: Bool

    public init(battery: PowerMode, ac: PowerMode, usesLegacyLowPowerKey: Bool) {
        self.battery = battery
        self.ac = ac
        self.usesLegacyLowPowerKey = usesLegacyLowPowerKey
    }

    /// The `pmset` key name to write for this machine.
    public var pmsetKey: String {
        usesLegacyLowPowerKey ? "lowpowermode" : "powermode"
    }

    /// The mode configured for `scope`, or nil for `.all` unless both power
    /// sources agree.
    public func mode(for scope: PowerModeScope) -> PowerMode? {
        switch scope {
        case .battery: return battery
        case .ac: return ac
        case .all: return battery == ac ? battery : nil
        }
    }
}

/// Parses `pmset -g custom` output. Readable unprivileged; writes need root.
public enum PowerModeParser {
    public enum ParseError: LocalizedError, Equatable {
        /// Neither the "Battery Power:" nor the "AC Power:" section was found.
        case missingSections
        /// A section exists but carries no `powermode`/`lowpowermode` key.
        case missingPowerModeKey(section: String)
        /// The key is present but its value is not a mode this build knows.
        case unrecognizedValue(section: String, value: String)

        public var errorDescription: String? {
            switch self {
            case .missingSections:
                return "pmset -g custom output had no Battery Power / AC Power sections"
            case .missingPowerModeKey(let section):
                return "pmset -g custom '\(section)' section had no powermode key"
            case .unrecognizedValue(let section, let value):
                return "pmset -g custom '\(section)' reported unrecognized powermode '\(value)'"
            }
        }
    }

    private static let batterySectionHeader = "Battery Power:"
    private static let acSectionHeader = "AC Power:"

    /// Extracts both sources' Energy Mode from `pmset -g custom` output.
    ///
    /// Keys are attributed strictly to the section header above them; unknown
    /// lines and surrounding whitespace are ignored. A machine exposing
    /// `lowpowermode` in either section is treated as legacy throughout,
    /// because the key name is a property of the hardware, not the source.
    public static func parse(pmsetCustomOutput: String) throws -> PowerModeState {
        var current: String?
        var values: [String: (mode: PowerMode, legacy: Bool)] = [:]
        var sawSection = false

        for rawLine in pmsetCustomOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == batterySectionHeader || line == acSectionHeader {
                current = line
                sawSection = true
                continue
            }
            guard let section = current, values[section] == nil else { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let key = String(fields[0])
            guard key == "powermode" || key == "lowpowermode" else { continue }

            let value = String(fields[1])
            guard let raw = Int(value), let mode = PowerMode(rawValue: raw) else {
                throw ParseError.unrecognizedValue(section: section, value: value)
            }
            values[section] = (mode, key == "lowpowermode")
        }

        guard sawSection else { throw ParseError.missingSections }
        guard let battery = values[batterySectionHeader] else {
            throw ParseError.missingPowerModeKey(section: batterySectionHeader)
        }
        guard let ac = values[acSectionHeader] else {
            throw ParseError.missingPowerModeKey(section: acSectionHeader)
        }

        return PowerModeState(
            battery: battery.mode,
            ac: ac.mode,
            usesLegacyLowPowerKey: battery.legacy || ac.legacy)
    }
}
