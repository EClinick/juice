import Foundation

/// One battery/power sample fed to the insights engine.
///
/// Discharge watts are positive; `watts` is 0 (or irrelevant) while on AC.
public struct InsightSample {
    public let date: Date
    public let percent: Int
    public let onAC: Bool
    public let isCharging: Bool
    public let watts: Double

    public init(date: Date, percent: Int, onAC: Bool, isCharging: Bool, watts: Double) {
        self.date = date
        self.percent = percent
        self.onAC = onAC
        self.isCharging = isCharging
        self.watts = watts
    }
}

/// Per-app energy for one calendar day.
public struct InsightAppDay {
    /// Calendar day in `yyyy-MM-dd` form.
    public let day: String
    public let appKey: String
    public let displayName: String
    public let wh: Double

    public init(day: String, appKey: String, displayName: String, wh: Double) {
        self.day = day
        self.appKey = appKey
        self.displayName = displayName
        self.wh = wh
    }
}

/// A single generated insight, stable per kind+subject.
public struct Insight: Identifiable, Equatable {
    /// Stable identifier per kind+subject.
    public let id: String
    public let kind: InsightKind
    public let title: String
    public let detail: String
    public let severity: InsightSeverity

    public init(id: String, kind: InsightKind, title: String, detail: String, severity: InsightSeverity) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

public enum InsightKind: String {
    case drainAnomaly
    case appAnomaly
    case hogOfWeek
    case chargingHabit
}

public enum InsightSeverity: Int, Comparable {
    case info = 0
    case notice = 1
    case warning = 2

    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
