import Foundation
import JuiceCore

enum BatterySessionFormatting {
    static func title(_ session: BatterySession) -> String {
        session.isActive ? "Current battery session" : "Last battery session"
    }

    static func boundary(_ session: BatterySession, calendar: Calendar = .current) -> String {
        if session.isActive {
            let prefix = session.isStartPartial ? "Recorded since" : "Since unplugged"
            return "\(prefix) · \(session.start.formatted(date: .omitted, time: .shortened))"
        }

        let startDate: Date.FormatStyle.DateStyle = calendar.isDate(session.start, inSameDayAs: session.end)
            ? .omitted : .abbreviated
        let start = session.start.formatted(date: startDate, time: .shortened)
        let end = session.end.formatted(date: .omitted, time: .shortened)
        return "Last battery session · \(start)–\(end)"
    }

    static func summary(_ session: BatterySession) -> String {
        "\(duration(session.duration)) · \(session.batteryPercentUsed)% used"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
