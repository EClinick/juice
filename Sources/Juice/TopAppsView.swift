import SwiftUI
import AppKit
import JuiceCore

/// Ranked list of per-app energy usage with a range picker. Session and Today
/// both lead with the shared live "drawing power now" section. Session pairs
/// that with exact off-charger energy; Today pairs it with calendar history.
struct TopAppsView: View {
    let apps: [AppEnergy]
    @Binding var range: EnergyRange
    let origin: DataOrigin
    /// Lets a surface retain its loading/error presentation while ensuring
    /// row taps use the correct underlying detail provider.
    var detailOrigin: DataOrigin? = nil
    var ranges = EnergyRange.allCases
    var showsRangePicker = true
    /// Server mode keeps current watts visible while the selected range only
    /// changes the accumulated energy context.
    var showsLiveAcrossRanges = false
    @State private var isSessionLiveExpanded = true
    @State private var isTodayLiveExpanded = true
    @AppStorage(ElectricityCost.pricePerKilowattHourStorageKey)
    private var pricePerKilowattHour = ElectricityCost.defaultPricePerKilowattHour
    /// The shared live/history result. Session reads its active rows and joins
    /// them with exact session energy; Today renders the result verbatim.
    var hybrid: HybridTodayList?
    /// Battery draw in watts for the live attribution footer.
    var batteryWatts: Double?
    /// Whole-system consumption in watts, available even while charging.
    var systemLoadWatts: Double?
    /// Selects the appropriate total-power source for the attribution footer.
    var onAC: Bool = false
    /// Total smoothed app watts for the live attribution footer.
    var totalAppWatts: Double?
    /// Exact battery-session context for the Session range. The same value is
    /// passed into app detail so every surface uses identical bounds.
    var session: BatterySession?

    /// Rows shown across both hybrid sections combined, matching the popover's
    /// former 8-row history cap.
    private static let hybridRowCap = 8

    /// Allocates cumulative rows without ever removing the section.
    /// Expanded live apps spend the shared budget first; collapsing Live gives
    /// history the full budget. Overflow consumes one row of its own.
    static func cumulativeRowCounts(
        activeCount: Int,
        appCount: Int,
        liveExpanded: Bool
    ) -> (visible: Int, folded: Int) {
        let rowBudget = liveExpanded
            ? max(2, hybridRowCap - activeCount)
            : hybridRowCap
        let visible = appCount > rowBudget
            ? max(1, rowBudget - 1)
            : appCount
        return (visible, max(0, appCount - visible))
    }

    static func shouldShowLiveSection(
        range: EnergyRange,
        showsLiveAcrossRanges: Bool,
        activeCount: Int
    ) -> Bool {
        guard activeCount > 0 else { return false }
        return showsLiveAcrossRanges || range == .today || range == .session
    }

    private var maxEnergy: Double {
        max(apps.map(\.energyWh).max() ?? 0, 0.001)
    }

    private func energyValueText(_ wattHours: Double) -> String {
        origin == .server
            ? serverEnergyText(wattHours)
            : String(format: "%.1f Wh", wattHours)
    }

    private func liveEnergyValueText(_ wattHours: Double?) -> String? {
        guard let wattHours, wattHours > 0 else { return nil }
        if origin == .server {
            return serverEnergyText(wattHours)
        }
        guard wattHours >= 0.05 else { return nil }
        return String(format: "%.1f Wh", wattHours)
    }

    private func costValueText(_ wattHours: Double?) -> String? {
        guard let wattHours else { return nil }
        return ElectricityCost.formattedEstimate(
            wattHours: wattHours,
            pricePerKilowattHour: pricePerKilowattHour)
    }

    private var historicalAppsIdentity: String {
        let originID: String
        switch origin {
        case .loading: originID = "loading"
        case .store: originID = "store"
        case .server: originID = "server"
        case .live: originID = "live"
        case .unavailable: originID = "unavailable"
        }
        return "\(range.rawValue)|\(originID)|\(apps.map(\.id).joined(separator: "|"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsRangePicker {
                Picker("Range", selection: $range) {
                    ForEach(ranges, id: \.self) { range in
                        Text(range.pickerLabel).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if range == .session, let session {
                VStack(alignment: .leading, spacing: 1) {
                    Text(BatterySessionFormatting.boundary(session))
                        .lineLimit(1)
                    Text(BatterySessionFormatting.summary(session))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let hybrid,
               Self.shouldShowLiveSection(
                   range: range,
                   showsLiveAcrossRanges: showsLiveAcrossRanges,
                   activeCount: hybrid.active.count) {
                if showsLiveAcrossRanges {
                    hybridRange(hybrid)
                } else if range == .session {
                    liveSession(hybrid)
                } else {
                    hybridToday(hybrid)
                }
            } else {
                historyList
            }

            if let footer = attribution() {
                LiveAttributionFooter(
                    appWatts: footer.appWatts,
                    systemWatts: footer.systemWatts)
            }
        }
    }

    /// The plain-history list used for Week / All Time and for Today when there
    /// is no live section to show yet. Today fetches the full app list for the
    /// hybrid's fold row, so cap the plain rendering to the popover budget.
    private var historyList: some View {
        VStack(spacing: 6) {
            ForEach(apps.prefix(Self.hybridRowCap)) { app in
                AppEnergyRow(
                    app: app,
                    fraction: app.energyWh / maxEnergy,
                    valueText: energyValueText(app.energyWh),
                    costText: costValueText(app.energyWh),
                    onTap: { showDetail(appKey: app.bundleId, displayName: app.displayName) })
            }
        }
        .id(historicalAppsIdentity)
        .transition(.opacity)
    }

    // MARK: - Hybrid Today

    private var rangeEnergyLabel: String {
        switch range {
        case .today: return "TODAY ENERGY"
        case .week: return "1W ENERGY"
        case .allTime: return "ALL ENERGY"
        default: return "\(range.rawValue.uppercased()) ENERGY"
        }
    }

    /// Server variant of the original hybrid pattern. Live watts remain at the
    /// top for every range; changing tabs only changes the Wh value and the
    /// historical rows below.
    @ViewBuilder
    private func hybridRange(_ hybrid: HybridTodayList) -> some View {
        let historyRows = Self.cumulativeRowCounts(
            activeCount: hybrid.active.count,
            appCount: hybrid.earlier.count,
            liveExpanded: isTodayLiveExpanded)
        let visibleHistory = Array(hybrid.earlier.prefix(historyRows.visible))
        let foldedHistory = hybrid.earlier.dropFirst(visibleHistory.count)
        let maxWatts = max(hybrid.active.map(\.watts).max() ?? 0, 0.001)
        let historyMax = max(visibleHistory.map(\.energyWh).max() ?? 0, 0.001)
        let totalLiveWatts = hybrid.active.reduce(0) { $0 + $1.watts }

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                CollapsibleLiveHeader(
                    isExpanded: $isTodayLiveExpanded,
                    appCount: hybrid.active.count,
                    totalWatts: totalLiveWatts)

                if isTodayLiveExpanded {
                    ForEach(hybrid.active) { app in
                        LiveActiveRow(
                            app: app,
                            energyText: liveEnergyValueText(app.todayWh),
                            range: range,
                            costText: costValueText(app.todayWh),
                            fraction: app.watts / maxWatts,
                            onTap: {
                                showDetail(appKey: app.appKey, displayName: app.displayName)
                            })
                    }
                }
            }

            if !visibleHistory.isEmpty || !foldedHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rangeEnergyLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(visibleHistory) { app in
                        AppEnergyRow(
                            app: app,
                            fraction: app.energyWh / historyMax,
                            valueText: energyValueText(app.energyWh),
                            costText: costValueText(app.energyWh),
                            onTap: {
                                showDetail(
                                    appKey: app.bundleId,
                                    displayName: app.displayName)
                            })
                    }
                    if !foldedHistory.isEmpty {
                        FoldedAppsRow(
                            count: foldedHistory.count,
                            valueText: energyValueText(
                                foldedHistory.reduce(0) { $0 + $1.energyWh }),
                            costText: costValueText(
                                foldedHistory.reduce(0) { $0 + $1.energyWh }))
                    }
                }
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func hybridToday(_ hybrid: HybridTodayList) -> some View {
        let historyRows = Self.cumulativeRowCounts(
            activeCount: hybrid.active.count,
            appCount: apps.count,
            liveExpanded: isTodayLiveExpanded)
        let visibleHistory = Array(apps.prefix(historyRows.visible))
        let foldedHistory = apps.dropFirst(visibleHistory.count)
        let maxWatts = max(hybrid.active.map(\.watts).max() ?? 0, 0.001)
        let historyMax = max(visibleHistory.map(\.energyWh).max() ?? 0, 0.001)
        let totalLiveWatts = hybrid.active.reduce(0) { $0 + $1.watts }

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                CollapsibleLiveHeader(
                    isExpanded: $isTodayLiveExpanded,
                    appCount: hybrid.active.count,
                    totalWatts: totalLiveWatts)

                if isTodayLiveExpanded {
                    ForEach(hybrid.active) { app in
                        LiveActiveRow(
                            app: app,
                            energyText: liveEnergyValueText(app.todayWh),
                            range: .today,
                            costText: costValueText(app.todayWh),
                            fraction: app.watts / maxWatts,
                            onTap: {
                                showDetail(appKey: app.appKey, displayName: app.displayName)
                            })
                    }
                }
            }

            if !visibleHistory.isEmpty || !foldedHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY ENERGY")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(visibleHistory) { app in
                        AppEnergyRow(
                            app: app,
                            fraction: app.energyWh / historyMax,
                            valueText: energyValueText(app.energyWh),
                            costText: costValueText(app.energyWh),
                            onTap: { showDetail(appKey: app.bundleId, displayName: app.displayName) })
                    }
                    if !foldedHistory.isEmpty {
                        FoldedAppsRow(
                            count: foldedHistory.count,
                            valueText: energyValueText(
                                foldedHistory.reduce(0) { $0 + $1.energyWh }),
                            costText: costValueText(
                                foldedHistory.reduce(0) { $0 + $1.energyWh }))
                    }
                }
            }
        }
        .transition(.opacity)
    }

    /// Session keeps every live app visible because current draw is the primary
    /// signal. The cumulative ranking remains below it in both disclosure
    /// states; collapsing Live only gives that ranking more of the row budget.
    @ViewBuilder
    private func liveSession(_ hybrid: HybridTodayList) -> some View {
        let sessionByKey = Dictionary(
            apps.map { ($0.bundleId, $0) },
            uniquingKeysWith: { first, _ in first })
        // Live rows spend the compact popover's budget first, but cumulative
        // Session data always keeps at least one app plus its overflow row.
        // Collapsing Live restores the complete eight-row history budget.
        let historyRows = Self.cumulativeRowCounts(
            activeCount: hybrid.active.count,
            appCount: apps.count,
            liveExpanded: isSessionLiveExpanded)
        let visibleHistory = Array(apps.prefix(historyRows.visible))
        let foldedHistory = apps.dropFirst(visibleHistory.count)
        let maxWatts = max(hybrid.active.map(\.watts).max() ?? 0, 0.001)
        let historyMax = max(visibleHistory.map(\.energyWh).max() ?? 0, 0.001)
        let totalLiveWatts = hybrid.active.reduce(0) { $0 + $1.watts }

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                CollapsibleLiveHeader(
                    isExpanded: $isSessionLiveExpanded,
                    appCount: hybrid.active.count,
                    totalWatts: totalLiveWatts)

                if isSessionLiveExpanded {
                    ForEach(hybrid.active) { app in
                        LiveActiveRow(
                            app: app,
                            energyText: liveEnergyValueText(
                                sessionByKey[app.appKey]?.energyWh),
                            range: .session,
                            costText: costValueText(
                                sessionByKey[app.appKey]?.energyWh),
                            fraction: app.watts / maxWatts,
                            onTap: {
                                showDetail(appKey: app.appKey, displayName: app.displayName)
                            })
                    }
                }
            }

            if !visibleHistory.isEmpty || !foldedHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSION ENERGY")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(visibleHistory) { app in
                        AppEnergyRow(
                            app: app,
                            fraction: app.energyWh / historyMax,
                            valueText: energyValueText(app.energyWh),
                            costText: costValueText(app.energyWh),
                            onTap: {
                                showDetail(appKey: app.bundleId, displayName: app.displayName)
                            })
                    }
                    if !foldedHistory.isEmpty {
                        FoldedAppsRow(
                            count: foldedHistory.count,
                            valueText: energyValueText(
                                foldedHistory.reduce(0) { $0 + $1.energyWh }),
                            costText: costValueText(
                                foldedHistory.reduce(0) { $0 + $1.energyWh }))
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func showDetail(appKey: String, displayName: String) {
        AppDetailPresenter.shared.show(
            appKey: appKey,
            displayName: displayName,
            range: range,
            origin: detailOrigin ?? origin,
            session: range == .session ? session : nil)
    }

    /// Apps versus system-and-display split for the footer. Battery draw is the
    /// total while unplugged; the power controller's system load is the total
    /// on AC, where battery watts instead describe charging.
    private func attribution() -> (appWatts: Double, systemWatts: Double)? {
        Self.attribution(
            appWatts: totalAppWatts,
            batteryWatts: batteryWatts,
            systemLoadWatts: systemLoadWatts,
            onAC: onAC)
    }

    static func attribution(
        appWatts: Double?,
        batteryWatts: Double?,
        systemLoadWatts: Double?,
        onAC: Bool
    ) -> (appWatts: Double, systemWatts: Double)? {
        let totalWatts = onAC ? systemLoadWatts : batteryWatts
        guard let totalWatts, totalWatts > 0, let appWatts else { return nil }
        let systemWatts = max(0, totalWatts - appWatts)
        return (appWatts, systemWatts)
    }
}

/// Watts formatting: one decimal from 0.1 W up, two decimals below. A
/// positive sub-centiwatt value is described as such instead of rounded to
/// the false reading "0.00 W".
func liveWattsText(_ watts: Double) -> String {
    if watts >= 0.1 {
        return String(format: "%.1f W", watts)
    }
    if watts > 0 && watts < 0.005 {
        return "<0.01 W"
    }
    return String(format: "%.2f W", watts)
}

/// Chart axes need distinct labels even when every tick is below the live
/// readout's centiwatt display threshold.
func chartWattsText(_ watts: Double) -> String {
    guard watts > 0, watts < 0.01 else { return liveWattsText(watts) }
    let milliwatts = watts * 1000
    if milliwatts >= 1 {
        return String(format: "%.1f mW", milliwatts)
    }
    if milliwatts >= 0.01 {
        return String(format: "%.2f mW", milliwatts)
    }
    return "<0.01 mW"
}

/// Shared disclosure control for the popover's Session and Today live layers.
private struct CollapsibleLiveHeader: View {
    @Binding var isExpanded: Bool
    let appCount: Int
    let totalWatts: Double

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                LiveDot()
                Text("DRAWING POWER NOW")
                Spacer()
                if !isExpanded {
                    Text("\(appCount) app\(appCount == 1 ? "" : "s") · \(liveWattsText(totalWatts))")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Drawing power now")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses live apps" : "Expands live apps")
    }
}

/// One active-power row in the hybrid Today view: 18 px icon, name with an
/// optional "· X.X Wh today" subtext, a bar scaled to the section max, and a
/// green watts value. Tapping opens the per-app detail window.
private struct LiveActiveRow: View {
    let app: HybridTodayList.ActiveApp
    let energyText: String?
    let range: EnergyRange
    let costText: String?
    let fraction: Double
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                AppIconView(bundleId: app.appKey, displayName: app.displayName)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    (Text(app.displayName)
                        .font(.caption)
                     + energySubtext)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                        }
                    }
                    .frame(height: 5)
                }

                VStack(alignment: .trailing, spacing: 1) {
                    Text(liveWattsText(app.watts))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    if let costText {
                        Text("\(compactCostContext) · \(costText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens energy details")
    }

    private var accessibilityValue: String {
        guard let costText else { return liveWattsText(app.watts) }
        return "\(liveWattsText(app.watts)), estimated cost \(costText) \(energyContext)"
    }

    private var energyContext: String {
        switch range {
        case .session: return "for this session"
        case .today: return "today"
        case .threeDays: return "over three days"
        case .week: return "this week"
        case .allTime: return "all time"
        }
    }

    /// Keep the period at the start so tail truncation can shorten a long
    /// localized currency value without ever hiding what the cost covers.
    private var compactCostContext: String {
        switch range {
        case .session: return "SESSION"
        case .today: return "TODAY"
        case .threeDays: return "3D"
        case .week: return "1W"
        case .allTime: return "ALL"
        }
    }

    private var energySubtext: Text {
        guard let energyText else { return Text("") }
        return Text(" · \(energyText) \(energyContext)")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// A dimmed summary row folding today's apps that did not fit the visible cap.
private struct FoldedAppsRow: View {
    let count: Int
    /// Pre-formatted value so each section folds in its own unit (W or Wh).
    let valueText: String
    let costText: String?

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                )
                .frame(width: 18, height: 18)

            Text("\(count) more app\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(valueText)
                    .font(.caption)
                if let costText {
                    Text(costText)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(width: 60, alignment: .trailing)
        }
    }
}

/// A two-segment stacked capsule with a caption legend splitting the battery
/// draw into app power and everything else (system and display).
private struct LiveAttributionFooter: View {
    let appWatts: Double
    let systemWatts: Double

    private var total: Double { max(appWatts + systemWatts, 0.001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(appWatts / total))
                    Capsule()
                        .fill(Color.secondary.opacity(0.4))
                }
            }
            .frame(height: 5)

            Text(String(format: "Apps %.1f W · System & display %.1f W", appWatts, systemWatts))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

/// One tappable row; tapping opens the per-app detail window. A chevron
/// appears on hover to hint at the interaction.
private struct AppEnergyRow: View {
    let app: AppEnergy
    let fraction: Double
    let valueText: String
    let costText: String?
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                AppIconView(bundleId: app.bundleId, displayName: app.displayName)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName)
                        .font(.caption)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                        }
                    }
                    .frame(height: 5)
                }

                VStack(alignment: .trailing, spacing: 1) {
                    Text(valueText)
                        .font(.caption)
                    if let costText {
                        Text(costText)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens energy details")
    }

    private var accessibilityValue: String {
        guard let costText else { return valueText }
        return "\(valueText), estimated cost \(costText)"
    }
}

/// The app's real icon when the bundle id resolves, otherwise a lettered placeholder.
struct AppIconView: View {
    let bundleId: String
    let displayName: String

    var body: some View {
        if let icon = Self.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.25))
                .overlay(
                    Text(String(displayName.prefix(1)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private static func icon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
