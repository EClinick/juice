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

    /// Names the active source's mode, and the inactive source's only when it
    /// is set differently. The orbit control carries no labels, so this caption
    /// is the only place the current mode is spelled out.
    static func footnote(_ state: PowerModeState?, onAC: Bool) -> String? {
        guard let state, let current = currentMode(state, onAC: onAC) else { return nil }
        guard state.battery != state.ac else { return current.displayName }
        let other = onAC
            ? "On battery: \(state.battery.displayName)"
            : "Plugged in: \(state.ac.displayName)"
        return "\(current.displayName) · \(other)"
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

/// The popover's top zone: a circular charge gauge carrying the Energy Mode
/// orbit control, beside the headline estimate and the health/cycles detail.
struct BatteryHeroRow: View {
    let reading: BatteryReading
    let timeRemainingText: String
    @ObservedObject var controller: EnergyModeController
    let isLowPowerModeEnabled: Bool
    var headlineOverride: String? = nil

    private var mode: PowerMode? {
        EnergyModePresentation.currentMode(controller.state, onAC: reading.onAC)
    }

    var body: some View {
        HStack(spacing: 12) {
            BatteryChargeGauge(
                percent: reading.percent,
                isCharging: reading.isCharging,
                tint: EnergyModePresentation.gaugeTint(
                    mode: mode,
                    percent: reading.percent,
                    onAC: reading.onAC,
                    isLowPowerModeEnabled: isLowPowerModeEnabled),
                avoidsOrbitBadge: controller.state != nil)
                // Top-aligned over a square the size of the ring: the gauge's
                // own frame grows at the bottom while charging, which would
                // otherwise shift the orbit's centre off the ring's centre.
                .overlay(alignment: .top) {
                    EnergyModeOrbit(controller: controller, onAC: reading.onAC)
                        .frame(
                            width: BatteryChargeGauge.defaultDiameter,
                            height: BatteryChargeGauge.defaultDiameter)
                }
                // The fan floats outside the ring and over the headline, so the
                // gauge must paint above the row's later siblings.
                .zIndex(1)

            VStack(alignment: .leading, spacing: 2) {
                Text(headlineOverride ?? EnergyModePresentation.headline(
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
    /// Shifts the charging badge off bottom-centre so it clears the Energy Mode
    /// badge docked at the ring's bottom-trailing edge.
    var avoidsOrbitBadge = false

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
                    .offset(x: avoidsOrbitBadge ? -7 : 0)
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


/// Placement rules for the Energy Mode orbit control. Kept out of the view so
/// the clearances between the badge, the fan, and the charging badge can be
/// asserted directly: they are the whole reason for these numbers.
enum EnergyModeOrbitGeometry {
    static let badgeDiameter: CGFloat = 22
    static let fanDiameter: CGFloat = 24
    /// Bottom-trailing, so the badge sits on the ring rather than beside it.
    static let badgeAngle = Angle.degrees(45)
    /// Distance of every fan button's centre from the badge's centre. The fan
    /// orbits the badge, not the gauge, so its padding reads uniform.
    static let fanOrbitRadius: CGFloat = 30

    /// Offset of the badge's centre from the gauge's centre, in view
    /// coordinates (positive y is down).
    static func badgeOffset(gaugeDiameter: CGFloat) -> CGPoint {
        offset(radius: gaugeDiameter / 2, angle: badgeAngle)
    }

    /// Angles around the BADGE (not the gauge): an arc from its trailing side
    /// down to just past vertical, so the open fan hugs the badge - right,
    /// below-right, below - without floating over the headline text. A lone
    /// button takes the middle of that arc, so it never reads as the first
    /// of a missing pair.
    static func fanAngles(count: Int) -> [Angle] {
        switch count {
        case ..<1: return []
        case 1: return [.degrees(50)]
        case 2: return [.degrees(0), .degrees(90)]
        default:
            let first = -5.0
            let last = 105.0
            let step = (last - first) / Double(count - 1)
            return (0..<count).map { .degrees(first + step * Double($0)) }
        }
    }

    static func fanOffsets(count: Int, gaugeDiameter: CGFloat) -> [CGPoint] {
        let badge = badgeOffset(gaugeDiameter: gaugeDiameter)
        return fanAngles(count: count).map {
            let orbit = offset(radius: fanOrbitRadius, angle: $0)
            return CGPoint(x: badge.x + orbit.x, y: badge.y + orbit.y)
        }
    }

    private static func offset(radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(
            x: radius * CGFloat(cos(angle.radians)),
            y: radius * CGFloat(sin(angle.radians)))
    }
}

/// The Energy Mode control, docked on the charge gauge: a badge showing the
/// active source's mode on the ring's bottom-trailing edge, which fans the other
/// modes out just beyond the ring when tapped.
struct EnergyModeOrbit: View {
    @ObservedObject var controller: EnergyModeController
    let onAC: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.juiceSurfaceIsActive) private var surfaceIsActive
    @State private var isExpanded = false

    private var selection: PowerMode? {
        EnergyModePresentation.currentMode(controller.state, onAC: onAC)
    }

    /// The full mode set: the fan always shows every available mode with the
    /// active one marked selected, so the open state reads as a complete
    /// picker rather than a pair of unexplained alternatives.
    private var fanModes: [PowerMode] {
        EnergyModePresentation.modes(showsHighPower: controller.showsHighPower)
    }

    var body: some View {
        ZStack {
            // No state means no readable Energy Mode - a desktop, or a failed
            // read - so the gauge carries no control at all.
            if let selection {
                if isExpanded {
                    let offsets = EnergyModeOrbitGeometry.fanOffsets(
                        count: fanModes.count,
                        gaugeDiameter: BatteryChargeGauge.defaultDiameter)
                    ForEach(Array(fanModes.enumerated()), id: \.element.rawValue) { index, mode in
                        EnergyModeFanButton(
                            mode: mode,
                            isSelected: mode == selection
                        ) { select(mode) }
                            .transition(fanTransition(index: index))
                            .offset(x: offsets[index].x, y: offsets[index].y)
                    }
                }

                EnergyModeBadge(
                    mode: selection,
                    isWriting: controller.isWriting,
                    isExpanded: isExpanded,
                    action: toggle)
                    .offset(
                        x: badgeOffset.x,
                        y: badgeOffset.y)
                    .disabled(controller.isWriting || controller.needsHelperUpdate)
            }
        }
        // A popover that is ordered out and reopened must come back collapsed.
        .onChange(of: surfaceIsActive) { _, isActive in
            if !isActive { isExpanded = false }
        }
        .onDisappear { isExpanded = false }
    }

    private var badgeOffset: CGPoint {
        EnergyModeOrbitGeometry.badgeOffset(
            gaugeDiameter: BatteryChargeGauge.defaultDiameter)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    private func select(_ mode: PowerMode) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            isExpanded = false
        }
        // Whether this is a real change is the controller's call: `selection`
        // is derived from this view's `onAC`, which lags the live power source,
        // so a tap that looks like a no-op here can still be a change to the
        // source actually in use.
        Task { await controller.set(mode, onAC: onAC) }
    }

    /// Fan in with a staggered pop out of focus, and leave with a quieter
    /// shrink: the exit is not the moment worth watching.
    private func fanTransition(index: Int) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertion = AnyTransition
            .modifier(
                active: EnergyModeFanEffect(opacity: 0, scale: 0.25, blur: 4),
                identity: EnergyModeFanEffect(opacity: 1, scale: 1, blur: 0))
            .animation(.easeOut(duration: 0.2).delay(Double(index) * 0.04))
        let removal = AnyTransition
            .modifier(
                active: EnergyModeFanEffect(opacity: 0, scale: 0.85, blur: 0),
                identity: EnergyModeFanEffect(opacity: 1, scale: 1, blur: 0))
            .animation(.easeIn(duration: 0.15))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private struct EnergyModeFanEffect: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// The docked badge: accent-filled, ringed in the popover's background colour so
/// it reads as sitting on top of the gauge's stroke.
private struct EnergyModeBadge: View {
    let mode: PowerMode
    let isWriting: Bool
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.accentColor)
                if isWriting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .tint(.white)
                } else {
                    Image(systemName: EnergyModePresentation.symbol(for: mode))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(
                width: EnergyModeOrbitGeometry.badgeDiameter,
                height: EnergyModeOrbitGeometry.badgeDiameter)
            .overlay {
                Circle().strokeBorder(.background, lineWidth: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(EnergyModeOrbitButtonStyle())
        .help("Energy Mode")
        .accessibilityLabel("Energy Mode: \(mode.displayName)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// One fanned-out mode, floating just outside the ring. The active mode is
/// filled with the accent so the open fan reads as a complete picker.
private struct EnergyModeFanButton: View {
    let mode: PowerMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Circle().fill(Color.accentColor)
                } else {
                    Circle().fill(.regularMaterial)
                    Circle().fill(.primary.opacity(isHovered ? 0.09 : 0))
                }
                Image(systemName: EnergyModePresentation.symbol(for: mode))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .frame(
                width: EnergyModeOrbitGeometry.fanDiameter,
                height: EnergyModeOrbitGeometry.fanDiameter)
            .overlay {
                Circle().strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(EnergyModeOrbitButtonStyle())
        .onHover { isHovered = $0 }
        .help("\(mode.displayName) Energy Mode")
        .accessibilityLabel("\(mode.displayName) Energy Mode")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The caption lines under the hero: the orbit control has no labels, so the
/// active mode is named here, followed by any helper or failure notice.
struct EnergyModeCaptions: View {
    @ObservedObject var controller: EnergyModeController
    let onAC: Bool

    private var footnote: String? {
        EnergyModePresentation.footnote(controller.state, onAC: onAC)
    }

    private var notice: String? {
        if controller.needsHelperUpdate {
            return "Switching Energy Mode needs the updated helper - restart Juice to update it."
        }
        return controller.lastErrorMessage
    }

    var body: some View {
        if footnote != nil || notice != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EnergyModeOrbitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
