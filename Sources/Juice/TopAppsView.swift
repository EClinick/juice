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
    @State private var isSessionLiveExpanded = true
    @State private var isTodayLiveExpanded = true
    /// The shared live/history result. Session reads its active rows and joins
    /// them with exact session energy; Today renders the result verbatim.
    var hybrid: HybridTodayList?
    /// Battery draw in watts for the live attribution footer.
    var batteryWatts: Double?
    /// The footer is omitted on AC, where battery watts mean charging rate.
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

    private var maxEnergy: Double {
        max(apps.map(\.energyWh).max() ?? 0, 0.001)
    }

    private var historicalAppsIdentity: String {
        let originID: String
        switch origin {
        case .loading: originID = "loading"
        case .store: originID = "store"
        case .live: originID = "live"
        case .unavailable: originID = "unavailable"
        }
        return "\(range.rawValue)|\(originID)|\(apps.map(\.id).joined(separator: "|"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $range) {
                ForEach(EnergyRange.allCases, id: \.self) { range in
                    Text(range.pickerLabel).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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

            if range == .session, let hybrid, !hybrid.active.isEmpty {
                liveSession(hybrid)
            } else if range == .today, let hybrid, !hybrid.active.isEmpty {
                hybridToday(hybrid)
            } else {
                historyList
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
                    onTap: { showDetail(appKey: app.bundleId, displayName: app.displayName) })
            }
        }
        .id(historicalAppsIdentity)
        .transition(.opacity)
    }

    // MARK: - Hybrid Today

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
                            energyWh: app.todayWh,
                            energyContext: "today",
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
                            onTap: { showDetail(appKey: app.bundleId, displayName: app.displayName) })
                    }
                    if !foldedHistory.isEmpty {
                        FoldedAppsRow(
                            count: foldedHistory.count,
                            valueText: String(
                                format: "%.1f Wh",
                                foldedHistory.reduce(0) { $0 + $1.energyWh }))
                    }
                }
            }

            if let footer = attribution() {
                LiveAttributionFooter(appWatts: footer.appWatts, systemWatts: footer.systemWatts)
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
                            energyWh: sessionByKey[app.appKey]?.energyWh,
                            energyContext: "session",
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
                            onTap: {
                                showDetail(appKey: app.bundleId, displayName: app.displayName)
                            })
                    }
                    if !foldedHistory.isEmpty {
                        FoldedAppsRow(
                            count: foldedHistory.count,
                            valueText: String(
                                format: "%.1f Wh",
                                foldedHistory.reduce(0) { $0 + $1.energyWh }))
                    }
                }
            }

            if let footer = attribution() {
                LiveAttributionFooter(appWatts: footer.appWatts, systemWatts: footer.systemWatts)
            }
        }
        .transition(.opacity)
    }

    private func showDetail(appKey: String, displayName: String) {
        AppDetailPresenter.shared.show(
            appKey: appKey,
            displayName: displayName,
            range: range,
            origin: origin,
            session: range == .session ? session : nil)
    }

    /// Apps versus system-and-display split for the footer, or nil when the
    /// battery watts are unavailable or we are on AC (where watts mean charge).
    private func attribution() -> (appWatts: Double, systemWatts: Double)? {
        guard !onAC, let batteryWatts, batteryWatts > 0, let totalAppWatts else { return nil }
        let systemWatts = max(0, batteryWatts - totalAppWatts)
        return (totalAppWatts, systemWatts)
    }
}

/// Watts formatting: one decimal from 0.1 W up, two decimals below.
func liveWattsText(_ watts: Double) -> String {
    if watts >= 0.1 {
        return String(format: "%.1f W", watts)
    }
    return String(format: "%.2f W", watts)
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
    let energyWh: Double?
    let energyContext: String
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

                Text(liveWattsText(app.watts))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)

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
        .accessibilityValue(liveWattsText(app.watts))
        .accessibilityHint("Opens energy details")
    }

    private var energySubtext: Text {
        // Below 0.05 Wh the value renders as "0.0" - noise, not information.
        guard let energyWh, energyWh >= 0.05 else { return Text("") }
        return Text(String(format: " · %.1f Wh %@", energyWh, energyContext))
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// A dimmed summary row folding today's apps that did not fit the visible cap.
private struct FoldedAppsRow: View {
    let count: Int
    /// Pre-formatted value so each section folds in its own unit (W or Wh).
    let valueText: String

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

            Text(valueText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
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

                Text(String(format: "%.1f Wh", app.energyWh))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)

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
        .accessibilityValue(String(format: "%.1f watt-hours", app.energyWh))
        .accessibilityHint("Opens energy details")
    }
}

/// The app's real icon when the bundle id resolves, otherwise a lettered placeholder.
private struct AppIconView: View {
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
