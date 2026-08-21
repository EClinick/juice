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

/// Which Energy Mode keys `pmset -g custom` publishes on this machine. The
/// layout is a hardware property, and it decides both how output is read and
/// how a change has to be written - see pmset(1) SETTINGS.
public enum PowerModeKeyLayout: String, Codable, Sendable {
    /// One tri-state `powermode` key per section: 0 Automatic, 1 Low, 2 High.
    /// Every current Mac.
    case unified
    /// Separate `lowpowermode` and `highpowermode` 0/1 keys per section, as
    /// shipped on the earlier Apple silicon machines that gained High Power.
    /// Both modes are reachable, but neither is expressed by a single key.
    case dualBoolean
    /// A `lowpowermode` 0/1 key with no `highpowermode` counterpart. Those
    /// machines have no High Power at all, so it must never be offered.
    case lowPowerOnly
}

/// The Energy Mode currently configured for each power source.
public struct PowerModeState: Codable, Sendable, Equatable {
    public var battery: PowerMode
    public var ac: PowerMode
    /// Which `pmset` keys this machine speaks, and therefore which commands a
    /// write has to issue.
    public var keyLayout: PowerModeKeyLayout
    /// True when `pmset -g custom` actually reported a "Battery Power:" section.
    /// Desktops have only "AC Power:", so their ``battery`` value is the AC
    /// setting mirrored rather than a second, independently settable source.
    public var hasBatterySource: Bool

    public init(
        battery: PowerMode,
        ac: PowerMode,
        keyLayout: PowerModeKeyLayout,
        hasBatterySource: Bool = true
    ) {
        self.battery = battery
        self.ac = ac
        self.keyLayout = keyLayout
        self.hasBatterySource = hasBatterySource
    }

    private enum CodingKeys: String, CodingKey {
        case battery, ac, keyLayout, usesLegacyLowPowerKey, hasBatterySource
    }

    /// ``keyLayout`` and ``hasBatterySource`` decode with defaults: the app and
    /// helper ship together, but the installed helper can lag the app by one
    /// launch, and a payload without the key must still load rather than fail
    /// the write. A payload that predates ``keyLayout`` carries the
    /// `usesLegacyLowPowerKey` boolean it replaced, which distinguishes only
    /// ``PowerModeKeyLayout/lowPowerOnly`` from ``PowerModeKeyLayout/unified``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decode(PowerMode.self, forKey: .battery)
        ac = try container.decode(PowerMode.self, forKey: .ac)
        if let layout = try container.decodeIfPresent(
            PowerModeKeyLayout.self, forKey: .keyLayout) {
            keyLayout = layout
        } else {
            let legacy =
                try container.decodeIfPresent(Bool.self, forKey: .usesLegacyLowPowerKey) ?? false
            keyLayout = legacy ? .lowPowerOnly : .unified
        }
        hasBatterySource =
            try container.decodeIfPresent(Bool.self, forKey: .hasBatterySource) ?? true
    }

    /// Emits the retired `usesLegacyLowPowerKey` boolean alongside
    /// ``keyLayout`` so a peer that predates the layout still reads the one
    /// thing it acts on: whether High Power exists.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(battery, forKey: .battery)
        try container.encode(ac, forKey: .ac)
        try container.encode(keyLayout, forKey: .keyLayout)
        try container.encode(usesLegacyLowPowerKey, forKey: .usesLegacyLowPowerKey)
        try container.encode(hasBatterySource, forKey: .hasBatterySource)
    }

    /// True when this machine exposes `lowpowermode` with no `highpowermode`
    /// counterpart, and so only accepts Automatic and Low Power.
    public var usesLegacyLowPowerKey: Bool {
        keyLayout == .lowPowerOnly
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
        /// A known section was present without a
        /// `powermode`/`lowpowermode`/`highpowermode` key. Names that section,
        /// or the first one seen when neither carried a key.
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

    /// One section's Energy Mode keys as `pmset` published them, and the mode
    /// they add up to.
    private struct SectionKeys {
        var powermode: PowerMode?
        var lowPower: Bool?
        var highPower: Bool?

        /// The section's mode and the key layout it was read from, or nil when
        /// the section carried no key this build knows.
        ///
        /// `powermode` is authoritative wherever it appears. Failing that, the
        /// booleans are combined, and `highpowermode` is read first: a section
        /// claiming both `lowpowermode 1` and `highpowermode 1` is reported as
        /// High Power, because that is the more specific enabled state and
        /// reading it as Low Power would understate what the machine is doing.
        var resolved: (mode: PowerMode, layout: PowerModeKeyLayout)? {
            if let powermode { return (powermode, .unified) }
            if let highPower {
                if highPower { return (.highPower, .dualBoolean) }
                return (lowPower == true ? .lowPower : .automatic, .dualBoolean)
            }
            if let lowPower { return (lowPower ? .lowPower : .automatic, .lowPowerOnly) }
            return nil
        }
    }

    /// Extracts both sources' Energy Mode from `pmset -g custom` output.
    ///
    /// Keys are attributed strictly to the section header above them; a header
    /// this build does not know ends attribution rather than leaking its keys
    /// into the previous source. The key layout is a property of the hardware,
    /// not of a source, so it is resolved across both sections: any section
    /// speaking the dual-boolean dialect makes the machine dual-boolean (High
    /// Power exists), and only a machine that offers `lowpowermode` alone
    /// anywhere - with no `highpowermode` in sight - is treated as having no
    /// High Power. Desktops publish only an "AC Power:" section, so a lone
    /// section is mirrored onto the other source; a section that is present but
    /// carries no mode key is a parse failure rather than something to mirror
    /// over.
    public static func parse(pmsetCustomOutput: String) throws -> PowerModeState {
        // nil means "no source owns the following keys": either nothing has been
        // seen yet, or the last header was one this build does not recognise.
        var current: String?
        var keys: [String: SectionKeys] = [:]
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
            let value = String(fields[1])
            var parsed = keys[section] ?? SectionKeys()

            switch key {
            case "powermode":
                // First occurrence wins, here and below: a repeated key is
                // `pmset` output this build has no rule for, and the earlier
                // line is the one it already believed.
                guard parsed.powermode == nil else { continue }
                guard let raw = Int(value), let mode = PowerMode(rawValue: raw) else {
                    throw ParseError.unrecognizedValue(section: section, value: value)
                }
                parsed.powermode = mode
            case "lowpowermode", "highpowermode":
                // Once `powermode` has spoken for the section the booleans are
                // never consulted, so their values are not judged either.
                guard parsed.powermode == nil else { continue }
                let isLowPower = key == "lowpowermode"
                guard (isLowPower ? parsed.lowPower : parsed.highPower) == nil else { continue }
                guard let flag = boolean(value) else {
                    throw ParseError.unrecognizedValue(section: section, value: value)
                }
                if isLowPower {
                    parsed.lowPower = flag
                } else {
                    parsed.highPower = flag
                }
            default:
                continue
            }
            keys[section] = parsed
        }

        // Mirroring is only ever right when the other section does not exist -
        // a desktop has no "Battery Power:" at all. A section that IS present
        // and carries no mode key is output this build does not understand, and
        // guessing its value from the other source would publish a mode the
        // machine never reported.
        let battery = keys[batterySectionHeader]?.resolved
        let ac = keys[acSectionHeader]?.resolved
        switch (battery, ac) {
        case let (battery?, ac?):
            return PowerModeState(
                battery: battery.mode,
                ac: ac.mode,
                keyLayout: layout(of: [battery.layout, ac.layout]),
                hasBatterySource: true)
        case let (battery?, nil):
            guard !knownSections.contains(acSectionHeader) else {
                throw ParseError.missingPowerModeKey(section: acSectionHeader)
            }
            return PowerModeState(
                battery: battery.mode,
                ac: battery.mode,
                keyLayout: battery.layout,
                hasBatterySource: true)
        case let (nil, ac?):
            guard !knownSections.contains(batterySectionHeader) else {
                throw ParseError.missingPowerModeKey(section: batterySectionHeader)
            }
            return PowerModeState(
                battery: ac.mode,
                ac: ac.mode,
                keyLayout: ac.layout,
                hasBatterySource: false)
        case (nil, nil):
            guard let first = knownSections.first else { throw ParseError.missingSections }
            throw ParseError.missingPowerModeKey(section: first)
        }
    }

    /// The machine's layout given what each section spoke. `highpowermode`
    /// anywhere proves High Power exists, so it outranks a section that only
    /// offered `lowpowermode`; that in turn outranks `powermode`, because a
    /// machine still publishing the older boolean will not take a tri-state
    /// write.
    private static func layout(of sections: [PowerModeKeyLayout]) -> PowerModeKeyLayout {
        if sections.contains(.dualBoolean) { return .dualBoolean }
        if sections.contains(.lowPowerOnly) { return .lowPowerOnly }
        return .unified
    }

    /// A `pmset` 0/1 flag. Anything else means the key is not the boolean this
    /// build takes it for, which is not something to guess at.
    private static func boolean(_ value: String) -> Bool? {
        switch value {
        case "0": return false
        case "1": return true
        default: return nil
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
