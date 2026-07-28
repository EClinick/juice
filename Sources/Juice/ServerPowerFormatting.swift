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
