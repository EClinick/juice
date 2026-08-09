import Foundation

/// Persistent visibility settings for the range tabs in the Stats window.
///
/// Values are stored as stable identifiers instead of display labels so the
/// copy can change without resetting a user's choices.
enum StatsRangeVisibility {
    static let storageKey = "stats.visibleRanges.v1"
    static let macMiniStorageKey = "stats.macMiniVisibleRanges.v1"
    /// Keep the compact popover readable on a fresh install. Three Days remains
    /// available through Customize Tabs, but the default avoids squeezing five
    /// segments into the menu-bar panel.
    static let defaultRanges: [EnergyRange] = [
        .session,
        .today,
        .week,
        .allTime,
    ]
    static let defaultStorageValue = storageValue(for: defaultRanges)
    static let allStorageValue = storageValue(for: EnergyRange.allCases)
    static let macMiniDefaultStorageValue = storageValue(for: macMiniPowerRanges)

    static func visibleRanges(
        from storageValue: String,
        availableRanges: [EnergyRange] = EnergyRange.allCases,
        fallbackRanges: [EnergyRange] = StatsRangeVisibility.defaultRanges
    ) -> [EnergyRange] {
        let storedKeys = Set(storageValue.split(separator: ",").map(String.init))
        let ranges = availableRanges.filter { storedKeys.contains($0.storageKey) }
        guard ranges.isEmpty else { return ranges }

        let availableSet = Set(availableRanges)
        let fallback = fallbackRanges.filter { availableSet.contains($0) }
        return fallback.isEmpty ? availableRanges : fallback
    }

    static func storageValue(for ranges: some Collection<EnergyRange>) -> String {
        let selected = Set(ranges)
        return EnergyRange.allCases
            .filter { selected.contains($0) }
            .map(\.storageKey)
            .joined(separator: ",")
    }

    static func preferredRange(
        _ preferredRange: EnergyRange,
        from storageValue: String,
        availableRanges: [EnergyRange] = EnergyRange.allCases,
        fallbackRanges: [EnergyRange] = StatsRangeVisibility.defaultRanges
    ) -> EnergyRange {
        let ranges = visibleRanges(
            from: storageValue,
            availableRanges: availableRanges,
            fallbackRanges: fallbackRanges)
        return ranges.contains(preferredRange) ? preferredRange : ranges[0]
    }

    static func updating(
        _ range: EnergyRange,
        isVisible: Bool,
        in storageValue: String,
        availableRanges: [EnergyRange] = EnergyRange.allCases,
        fallbackRanges: [EnergyRange] = StatsRangeVisibility.defaultRanges
    ) -> String {
        var visible = Set(visibleRanges(
            from: storageValue,
            availableRanges: availableRanges,
            fallbackRanges: fallbackRanges))
        if isVisible {
            if availableRanges.contains(range) {
                visible.insert(range)
            }
        } else if visible.count > 1 {
            visible.remove(range)
        }
        return self.storageValue(for: visible)
    }
}

private extension EnergyRange {
    var storageKey: String {
        switch self {
        case .session: return "session"
        case .today: return "today"
        case .threeDays: return "threeDays"
        case .week: return "week"
        case .allTime: return "allTime"
        }
    }
}
