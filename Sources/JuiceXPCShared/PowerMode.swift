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
    /// True when `pmset -g custom` actually reported a "Battery Power:" section.
    /// Desktops have only "AC Power:", so their ``battery`` value is the AC
    /// setting mirrored rather than a second, independently settable source.
    public var hasBatterySource: Bool

    public init(
        battery: PowerMode,
        ac: PowerMode,
        usesLegacyLowPowerKey: Bool,
        hasBatterySource: Bool = true
    ) {
        self.battery = battery
        self.ac = ac
        self.usesLegacyLowPowerKey = usesLegacyLowPowerKey
        self.hasBatterySource = hasBatterySource
    }

    private enum CodingKeys: String, CodingKey {
        case battery, ac, usesLegacyLowPowerKey, hasBatterySource
    }

    /// ``hasBatterySource`` decodes with a default: the app and helper ship
    /// together, but the installed helper can lag the app by one launch, and a
    /// payload without the key must still load rather than fail the write.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decode(PowerMode.self, forKey: .battery)
        ac = try container.decode(PowerMode.self, forKey: .ac)
        usesLegacyLowPowerKey = try container.decode(Bool.self, forKey: .usesLegacyLowPowerKey)
        hasBatterySource =
            try container.decodeIfPresent(Bool.self, forKey: .hasBatterySource) ?? true
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
        /// A known section was present without a `powermode`/`lowpowermode`
        /// key. Names that section, or the first one seen when neither carried
        /// a key.
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
    /// Keys are attributed strictly to the section header above them; a header
    /// this build does not know ends attribution rather than leaking its keys
    /// into the previous source. A machine exposing `lowpowermode` in either
    /// section is treated as legacy throughout, because the key name is a
    /// property of the hardware, not the source. Desktops publish only an
    /// "AC Power:" section, so a lone section is mirrored onto the other source;
    /// a section that is present but carries no mode key is a parse failure
    /// rather than something to mirror over.
    public static func parse(pmsetCustomOutput: String) throws -> PowerModeState {
        // nil means "no source owns the following keys": either nothing has been
        // seen yet, or the last header was one this build does not recognise.
        var current: String?
        var values: [String: (mode: PowerMode, legacy: Bool)] = [:]
        var knownSections: [String] = []

        for rawLine in pmsetCustomOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == batterySectionHeader || line == acSectionHeader {
                current = line
                if !knownSections.contains(line) { knownSections.append(line) }
                continue
            }
            if isSectionHeader(rawLine: rawLine, line: line) {
                current = nil
                continue
            }
            guard let section = current else { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let key = String(fields[0])
            guard key == "powermode" || key == "lowpowermode" else { continue }

            // A section can carry both keys. `powermode` is the authoritative
            // one, so it wins whichever order they appear in.
            let legacy = key == "lowpowermode"
            if let existing = values[section], !(existing.legacy && !legacy) { continue }

            let value = String(fields[1])
            guard let raw = Int(value), let mode = PowerMode(rawValue: raw) else {
                throw ParseError.unrecognizedValue(section: section, value: value)
            }
            values[section] = (mode, legacy)
        }

        // Mirroring is only ever right when the other section does not exist -
        // a desktop has no "Battery Power:" at all. A section that IS present
        // and carries no mode key is output this build does not understand, and
        // guessing its value from the other source would publish a mode the
        // machine never reported.
        switch (values[batterySectionHeader], values[acSectionHeader]) {
        case let (battery?, ac?):
            return PowerModeState(
                battery: battery.mode,
                ac: ac.mode,
                usesLegacyLowPowerKey: battery.legacy || ac.legacy,
                hasBatterySource: true)
        case let (battery?, nil):
            guard !knownSections.contains(acSectionHeader) else {
                throw ParseError.missingPowerModeKey(section: acSectionHeader)
            }
            return PowerModeState(
                battery: battery.mode,
                ac: battery.mode,
                usesLegacyLowPowerKey: battery.legacy,
                hasBatterySource: true)
        case let (nil, ac?):
            guard !knownSections.contains(batterySectionHeader) else {
                throw ParseError.missingPowerModeKey(section: batterySectionHeader)
            }
            return PowerModeState(
                battery: ac.mode,
                ac: ac.mode,
                usesLegacyLowPowerKey: ac.legacy,
                hasBatterySource: false)
        case (nil, nil):
            guard let first = knownSections.first else { throw ParseError.missingSections }
            throw ParseError.missingPowerModeKey(section: first)
        }
    }

    /// Whether a line introduces a section rather than carrying a key. `pmset`
    /// indents every key under its header, so a flush-left label - or anything
    /// ending in "Power:" - starts a section, known or not.
    private static func isSectionHeader(rawLine: Substring, line: String) -> Bool {
        if line.hasSuffix("Power:") { return true }
        guard let first = rawLine.first else { return false }
        return !first.isWhitespace
    }
}
