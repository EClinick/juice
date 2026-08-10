import SwiftUI
import JuiceXPCShared

/// Pure presentation rules for the popover's battery hero and Energy Mode
/// picker, kept out of the views so they can be tested directly.
enum EnergyModePresentation {
    /// Display order, matching System Settings: least to most power.
    static let modeOrder: [PowerMode] = [.lowPower, .automatic, .highPower]

    /// The mode configured for the source currently in use. Selection always
    /// describes the active source, because that is what a tap would change.
    static func currentMode(_ state: PowerModeState?, onAC: Bool) -> PowerMode? {
        guard let state else { return nil }
        return onAC ? state.ac : state.battery
    }

    static func modes(showsHighPower: Bool) -> [PowerMode] {
        showsHighPower ? modeOrder : modeOrder.filter { $0 != .highPower }
    }

    static func tint(for mode: PowerMode) -> Color {
        switch mode {
        case .lowPower: return .yellow
        case .automatic: return .gray
        case .highPower: return .cyan
        }
    }

    /// Ring tint: the Energy Mode colour when known, otherwise the menu bar
    /// icon's charge-level priority so the two never disagree.
    static func gaugeTint(
        mode: PowerMode?,
        percent: Int,
        onAC: Bool,
        isLowPowerModeEnabled: Bool
    ) -> Color {
        if let mode { return tint(for: mode) }
        switch BatteryStatusIcon.fillStyle(
            percent: percent,
            onAC: onAC,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        ) {
        case .lowBattery: return .red
        case .lowPower: return .yellow
        case .standard: return .gray
        }
    }

    /// Mentions the inactive power source only when it is set differently, so
    /// the common case stays a single row of buttons.
    static func otherSourceFootnote(_ state: PowerModeState?, onAC: Bool) -> String? {
        guard let state, state.battery != state.ac else { return nil }
        return onAC
            ? "On battery: \(state.battery.displayName)"
            : "Plugged in: \(state.ac.displayName)"
    }

    static func headline(_ reading: BatteryReading, timeRemainingText: String) -> String {
        guard reading.onAC else { return timeRemainingText }
        return reading.isCharging
            ? String(format: "Charging at %.1f W", abs(reading.watts))
            : "Plugged in, not charging"
    }

    static func detail(_ reading: BatteryReading) -> String {
        var parts: [String] = []
        if !reading.onAC {
            parts.append(String(format: "Drawing %.1f W", abs(reading.watts)))
        }
        if let health = reading.healthPercent {
            parts.append("Health \(health)%")
        }
        parts.append("\(reading.cycleCount) cycles")
        return parts.joined(separator: " · ")
    }

    static func symbol(for mode: PowerMode) -> String {
        switch mode {
        case .lowPower: return "leaf.fill"
        case .automatic: return "speedometer"
        case .highPower: return "bolt.fill"
        }
    }
}

/// The popover's top zone: a circular charge gauge beside the headline estimate
/// and the health/cycles detail line.
struct BatteryHeroRow: View {
    let reading: BatteryReading
    let timeRemainingText: String
    let mode: PowerMode?
    let isLowPowerModeEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            BatteryChargeGauge(
                percent: reading.percent,
                isCharging: reading.isCharging,
                tint: EnergyModePresentation.gaugeTint(
                    mode: mode,
                    percent: reading.percent,
                    onAC: reading.onAC,
                    isLowPowerModeEnabled: isLowPowerModeEnabled))

            VStack(alignment: .leading, spacing: 2) {
                Text(EnergyModePresentation.headline(
                    reading,
                    timeRemainingText: timeRemainingText))
                    .font(.headline)
                Text(EnergyModePresentation.detail(reading))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Ring gauge for the charge level, tinted by Energy Mode.
struct BatteryChargeGauge: View {
    static let defaultDiameter: CGFloat = 58

    let percent: Int
    let isCharging: Bool
    let tint: Color
    var diameter: CGFloat = defaultDiameter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lineWidth: CGFloat { 5 }
    private var fraction: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            // Inset by half the line width: a centered stroke on the frame's
            // edge would draw outside the layout bounds and get clipped by
            // the popover edge.
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
                .padding(lineWidth / 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start the arc at 12 o'clock like the system's charge rings.
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
            Text("\(percent)%")
                .font(.headline.monospacedDigit())
        }
        .frame(width: diameter, height: diameter)
        .padding(.bottom, isCharging ? 3 : 0)
        .overlay(alignment: .bottom) {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(tint, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.background, lineWidth: 1.5)
                    }
            }
        }
        // Value-scoped so the first render lands without animating.
        .animation(gaugeAnimation, value: fraction)
        .animation(gaugeAnimation, value: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isCharging
                ? "Battery \(percent) percent, charging"
                : "Battery \(percent) percent")
    }

    private var gaugeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}

/// Control Center style Energy Mode picker: one circle-and-label button per
/// mode, selecting the mode of the power source currently in use.
struct EnergyModePicker: View {
    @ObservedObject var controller: EnergyModeController
    let onAC: Bool

    private var selection: PowerMode? {
        EnergyModePresentation.currentMode(controller.state, onAC: onAC)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Every column is pinned to the gauge's width and separated by
            // equal flexible spacers: the first circle sits centered under
            // the ring and the circle centers stay evenly spaced. Flexible
            // equal-third columns would drift the first circle ~20 pt
            // trailing of the gauge's axis.
            HStack(spacing: 0) {
                let modes = EnergyModePresentation.modes(
                    showsHighPower: controller.showsHighPower)
                ForEach(Array(modes.enumerated()), id: \.element.rawValue) { index, mode in
                    if index > 0 { Spacer(minLength: 8) }
                    EnergyModeButton(
                        mode: mode,
                        isSelected: mode == selection,
                        isPending: controller.pendingMode == mode
                    ) {
                        Task { await controller.set(mode, onAC: onAC) }
                    }
                    .frame(width: BatteryChargeGauge.defaultDiameter)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(controller.isWriting || controller.needsHelperUpdate)

            if let footnote = EnergyModePresentation.otherSourceFootnote(
                controller.state,
                onAC: onAC
            ) {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if controller.needsHelperUpdate {
                Text("Switching Energy Mode needs the updated helper - restart Juice to update it.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let message = controller.lastErrorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EnergyModeButton: View {
    let mode: PowerMode
    let isSelected: Bool
    let isPending: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    // The system accent for every selected mode: per-mode tints
                    // (yellow, cyan) clash with the white glyph on top of them.
                    Circle()
                        .fill(isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.quaternary))
                        .frame(width: 26, height: 26)
                    if isPending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: EnergyModePresentation.symbol(for: mode))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                Text(mode.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    // Labels may be wider than the pinned first column; let
                    // them spill symmetrically instead of truncating.
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(EnergyModeButtonStyle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSelected)
        .help("\(mode.displayName) Energy Mode")
        .accessibilityLabel("\(mode.displayName) Energy Mode")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct EnergyModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
