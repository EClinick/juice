import Foundation
import JuiceCore

/// Server energy formatting shared by the popover and Mac mini Stats.
///
/// Small, positive readings switch to milliwatt-hours so they are never
/// presented as zero merely because less precision fits the Wh unit.
func serverEnergyText(_ wattHours: Double) -> String {
    guard wattHours > 0 else { return "0 Wh" }
    if wattHours >= 1000 {
        return String(format: "%.2f kWh", wattHours / 1000)
    }
    if wattHours >= 10 {
        return String(format: "%.0f Wh", wattHours)
    }
    if wattHours >= 0.1 {
        return String(format: "%.1f Wh", wattHours)
    }

    let milliwattHours = wattHours * 1000
    if milliwattHours >= 10 {
        return String(format: "%.0f mWh", milliwattHours)
    }
    if milliwattHours >= 1 {
        return String(format: "%.1f mWh", milliwattHours)
    }
    if milliwattHours >= 0.01 {
        return String(format: "%.2f mWh", milliwattHours)
    }
    return "<0.01 mWh"
}

func serverActiveDurationText(_ activeHours: Double) -> String {
    let seconds = max(0, activeHours * 3600)
    if seconds >= 3600 {
        let displayedHours = ((seconds / 3600) * 10).rounded() / 10
        let hoursText = String(format: "%.1f", displayedHours)
        return "\(hoursText) \(displayedHours == 1 ? "hour" : "hours")"
    }
    if seconds >= 60 {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
    if seconds > 0 {
        let wholeSeconds = max(1, Int(seconds.rounded()))
        return "\(wholeSeconds) \(wholeSeconds == 1 ? "second" : "seconds")"
    }
    return "0 seconds"
}

/// Formats the current boot's wall-clock age for compact Stats cards. This is
/// intentionally separate from selected-range monitoring coverage: uptime is
/// always measured since the last system restart.
func systemUptimeText(_ uptime: TimeInterval) -> String {
    guard uptime.isFinite, uptime > 0 else { return "0m" }
    if uptime < 60 { return "<1m" }

    let totalMinutes = Int(min(
        floor(uptime / 60),
        Double(Int.max / 2)))
    let days = totalMinutes / (24 * 60)
    let hours = totalMinutes / 60 % 24
    let minutes = totalMinutes % 60

    if days > 0 {
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(minutes)m"
}

/// Uses the exact same live reading and watt formatter on every Mac mini
/// surface, with Stats optionally appending the already-summed total.
func serverPowerBreakdownText(
    _ reading: LivePowerReading,
    includesMeteredTotal: Bool
) -> String {
    var text = "Apps \(liveWattsText(reading.totalAppWatts))"
        + " · System processes \(liveWattsText(reading.systemWatts))"
    if includesMeteredTotal {
        text += " · Metered \(liveWattsText(reading.totalMeteredWatts))"
    }
    return text
}
