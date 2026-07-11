import SwiftUI
import AppKit
import JuiceCore

/// Ranked list of per-app energy usage with a range picker. On ``.today`` the
/// view is a hybrid: a live "drawing power now" section on top of today's
/// energy history. Week and All Time are pure history.
struct TopAppsView: View {
    let apps: [AppEnergy]
    @Binding var range: EnergyRange
    let origin: DataOrigin
    /// The merged live/history split for the Today view. Present only when
    /// ``range`` is ``.today`` and live sampling has produced a reading; nil
    /// otherwise (Today then renders as plain history).
    var hybrid: HybridTodayList?
    /// Battery draw in watts for the live attribution footer; nil off ``.today``.
    var batteryWatts: Double?
    /// The footer is omitted on AC, where battery watts mean charging rate.
    var onAC: Bool = false
    /// Total smoothed app watts for the live attribution footer.
    var totalAppWatts: Double?

    /// Rows shown across both hybrid sections combined, matching the popover's
    /// former 8-row history cap.
    private static let hybridRowCap = 8

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

            if range == .today, let hybrid, !hybrid.active.isEmpty {
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

    /// The hybrid's row plan: which rows render in each section and what each
    /// section's fold row absorbs. Active rows spend the budget first; each
    /// section folds its own overflow (in its own unit - watts above, Wh
    /// below) so a currently-active app is never miscategorized as history.
    /// Rows including fold rows never exceed ``hybridRowCap``, so the hybrid
    /// cannot outgrow the plain 8-row list it replaced.
    private struct HybridRowPlan {
        let visibleActive: [HybridTodayList.ActiveApp]
        let foldedActiveCount: Int
        let foldedActiveWatts: Double
        let visibleEarlier: [AppEnergy]
        let foldedEarlierCount: Int
        let foldedEarlierWh: Double
    }

    private static func rowPlan(for hybrid: HybridTodayList) -> HybridRowPlan {
        let cap = hybridRowCap
        let activeCount = hybrid.active.count
        let earlierCount = hybrid.earlier.count

        let activeCap: Int
        let earlierCap: Int
        if activeCount + earlierCount <= cap {
            activeCap = activeCount
            earlierCap = earlierCount
        } else if activeCount < cap {
            // Active fits; the earlier section overflows and pays one slot
            // for its fold row (possibly collapsing to just the fold).
            activeCap = activeCount
            earlierCap = cap - activeCount - 1
        } else if earlierCount == 0 {
            // Only active rows overflow; one slot for their fold row.
            activeCap = cap - 1
            earlierCap = 0
        } else {
            // Both sections need a fold row; earlier collapses to just its
            // fold so the live section keeps the most rows.
            activeCap = cap - 2
            earlierCap = 0
        }

        let foldedActive = hybrid.active.dropFirst(activeCap)
        let foldedEarlier = hybrid.earlier.dropFirst(earlierCap)
        return HybridRowPlan(
            visibleActive: Array(hybrid.active.prefix(activeCap)),
            foldedActiveCount: foldedActive.count,
            foldedActiveWatts: foldedActive.reduce(0) { $0 + $1.watts },
            visibleEarlier: Array(hybrid.earlier.prefix(earlierCap)),
            foldedEarlierCount: foldedEarlier.count,
            foldedEarlierWh: foldedEarlier.reduce(0) { $0 + $1.energyWh }
        )
    }

    @ViewBuilder
    private func hybridToday(_ hybrid: HybridTodayList) -> some View {
        let plan = Self.rowPlan(for: hybrid)
        let maxWatts = max(plan.visibleActive.map(\.watts).max() ?? 0, 0.001)
        let earlierMax = max(plan.visibleEarlier.map(\.energyWh).max() ?? 0, 0.001)

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    LiveDot()
                    Text("DRAWING POWER NOW")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(plan.visibleActive) { app in
                    LiveActiveRow(
                        app: app,
                        fraction: app.watts / maxWatts,
                        onTap: { showDetail(appKey: app.appKey, displayName: app.displayName) })
                }
                if plan.foldedActiveCount > 0 {
                    FoldedAppsRow(
                        count: plan.foldedActiveCount,
                        valueText: liveWattsText(plan.foldedActiveWatts))
                }
            }

            if !plan.visibleEarlier.isEmpty || plan.foldedEarlierCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EARLIER TODAY")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(plan.visibleEarlier) { app in
                        AppEnergyRow(
                            app: app,
                            fraction: app.energyWh / earlierMax,
                            onTap: { showDetail(appKey: app.bundleId, displayName: app.displayName) })
                    }
                    if plan.foldedEarlierCount > 0 {
                        FoldedAppsRow(
                            count: plan.foldedEarlierCount,
                            valueText: String(format: "%.1f Wh", plan.foldedEarlierWh))
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
            origin: origin)
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

/// One active-power row in the hybrid Today view: 18 px icon, name with an
/// optional "· X.X Wh today" subtext, a bar scaled to the section max, and a
/// green watts value. Tapping opens the per-app detail window.
private struct LiveActiveRow: View {
    let app: HybridTodayList.ActiveApp
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
                     + todaySubtext)
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

    private var todaySubtext: Text {
        // Below 0.05 Wh the value renders as "0.0" - noise, not information.
        guard let wh = app.todayWh, wh >= 0.05 else { return Text("") }
        return Text(String(format: " · %.1f Wh today", wh))
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
