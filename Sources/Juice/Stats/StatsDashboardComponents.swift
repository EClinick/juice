import Foundation
import SwiftUI

/// The shared page structure for every Stats dashboard. Battery and server
/// modes supply different data panes, but the window anatomy and spacing stay
/// identical.
struct StatsDashboardLayout<Header: View, AppPane: View, DetailPane: View, Footer: View>: View {
    let minimumContentWidth: CGFloat
    let minimumAppPaneWidth: CGFloat
    let minimumDetailPaneWidth: CGFloat
    let minimumContentHeight: CGFloat

    private let header: Header
    private let appPane: AppPane
    private let detailPane: DetailPane
    private let footer: Footer

    init(
        minimumContentWidth: CGFloat,
        minimumAppPaneWidth: CGFloat,
        minimumDetailPaneWidth: CGFloat,
        minimumContentHeight: CGFloat,
        @ViewBuilder header: () -> Header,
        @ViewBuilder appPane: () -> AppPane,
        @ViewBuilder detailPane: () -> DetailPane,
        @ViewBuilder footer: () -> Footer
    ) {
        self.minimumContentWidth = minimumContentWidth
        self.minimumAppPaneWidth = minimumAppPaneWidth
        self.minimumDetailPaneWidth = minimumDetailPaneWidth
        self.minimumContentHeight = minimumContentHeight
        self.header = header()
        self.appPane = appPane()
        self.detailPane = detailPane()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                appPane
                    .frame(minWidth: minimumAppPaneWidth)
                Divider()
                detailPane
                    .frame(minWidth: minimumDetailPaneWidth)
            }

            Divider()
            footer
        }
        .frame(
            minWidth: minimumContentWidth,
            minHeight: minimumContentHeight)
    }
}

/// The shared title and control-stack anatomy for every Stats mode. Each mode
/// supplies only the actions and controls that make sense for its data source.
struct StatsDashboardHeader<Actions: View, Controls: View>: View {
    let title: String
    let subtitle: String

    private let actions: Actions
    private let controls: Controls

    init(
        title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            controls
        }
        .padding(16)
    }
}

struct AppTableSortValues {
    let stableID: String
    let displayName: String
    let liveWatts: Double?
    let energyWh: Double?
    let detail: Double?
}

/// Live watts are compared at the precision the row actually displays, so two
/// rows showing the same number never trade places between samples.
func displayedLiveWatts(_ watts: Double) -> Double {
    // Ties round to even to match String(format:)'s IEEE behavior, so an
    // exact midpoint like 0.25 W keys as the 0.2 it displays, never 0.3.
    watts >= 0.1
        ? (watts * 10).rounded(.toNearestOrEven) / 10
        : (watts * 100).rounded(.toNearestOrEven) / 100
}

/// A user-chosen column sort for a Stats app table. A `nil` sort means no
/// column is selected and the table keeps the natural order its caller
/// supplies, which is what preserves live-row hysteresis.
struct AppTableSort: Equatable {
    enum Column: Equatable {
        case app
        case liveWatts
        case energy
        case detail
    }

    enum Direction: Equatable {
        case ascending
        case descending
    }

    var column: Column
    var direction: Direction

    /// The direction a column starts in the first time it is chosen.
    static func naturalDirection(for column: Column) -> Direction {
        column == .app ? .ascending : .descending
    }

    /// Header clicks cycle one column through its natural direction, the
    /// reversed direction, and then back to no sort at all.
    static func select(_ column: Column, from current: AppTableSort?) -> AppTableSort? {
        let natural = naturalDirection(for: column)
        guard let current, current.column == column else {
            return AppTableSort(column: column, direction: natural)
        }
        guard current.direction == natural else { return nil }
        return AppTableSort(
            column: column,
            direction: natural == .ascending ? .descending : .ascending)
    }

    /// Sorting by live watts falls back to energy when none of the visible rows
    /// carry live values, so the column stays useful in historical sections.
    func effectiveColumn(hasLiveWatts: Bool) -> Column {
        column == .liveWatts && !hasLiveWatts ? .energy : column
    }

    static func apply<Row>(
        _ sort: AppTableSort?,
        to rows: [Row],
        query: String,
        values: (Row) -> AppTableSortValues
    ) -> [Row] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = rows
            .map { (row: $0, values: values($0)) }
            .filter {
                filter.isEmpty || $0.values.displayName.localizedStandardContains(filter)
            }
        guard let sort else { return candidates.map(\.row) }

        let effectiveColumn = sort.effectiveColumn(
            hasLiveWatts: candidates.contains { $0.values.liveWatts != nil })

        func namePrecedes(_ lhs: AppTableSortValues, _ rhs: AppTableSortValues) -> Bool {
            let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.stableID.localizedStandardCompare(rhs.stableID) == .orderedAscending
        }

        func numericValue(_ values: AppTableSortValues) -> Double? {
            switch effectiveColumn {
            case .app:
                return nil
            case .liveWatts:
                return values.liveWatts.map(displayedLiveWatts)
            case .energy:
                return values.energyWh
            case .detail:
                return values.detail
            }
        }

        return candidates.sorted { lhs, rhs in
            if effectiveColumn == .app {
                let nameOrder = lhs.values.displayName.localizedStandardCompare(
                    rhs.values.displayName)
                if nameOrder != .orderedSame {
                    return sort.direction == .ascending
                        ? nameOrder == .orderedAscending
                        : nameOrder == .orderedDescending
                }
                return lhs.values.stableID.localizedStandardCompare(rhs.values.stableID)
                    == .orderedAscending
            }

            switch (numericValue(lhs.values), numericValue(rhs.values)) {
            case let (left?, right?) where left != right:
                return sort.direction == .ascending ? left < right : left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return namePrecedes(lhs.values, rhs.values)
            }
        }
        .map { $0.row }
    }
}

/// The one ease Juice uses whenever on-screen content is replaced or
/// reordered - the popover's app list, the Stats range controls, and every
/// Stats app table share it so those swaps never feel like different products.
let juiceStandardEase = Animation.timingCurve(
    0.23,
    1,
    0.32,
    1,
    duration: 0.18)

/// Column configuration shared by battery and server app tables.
struct StatsAppTableColumns: Equatable {
    let showsLiveWatts: Bool
    let detailTitle: String
    let detailWidth: CGFloat

    static func battery(showsLiveWatts: Bool) -> Self {
        Self(
            showsLiveWatts: showsLiveWatts,
            detailTitle: "CPU TIME",
            detailWidth: 72)
    }

    static let server = Self(
        showsLiveWatts: true,
        detailTitle: "PEAK W",
        detailWidth: 64)
}

/// The titled columns above every Stats app table. Its dimensions mirror
/// ``StatsAppTableRow`` so labels remain aligned in every device mode.
struct StatsAppTableHeader: View {
    let columns: StatsAppTableColumns
    @Binding var sort: AppTableSort?

    var body: some View {
        HStack(spacing: 10) {
            StatsAppTableHeaderButton(
                title: "APP",
                column: .app,
                alignment: .leading,
                indicatorBeforeLabel: false,
                direction: direction(for: .app),
                onSelect: { select(.app) })
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsLiveWatts {
                StatsAppTableHeaderButton(
                    title: "LIVE W",
                    column: .liveWatts,
                    alignment: .trailing,
                    indicatorBeforeLabel: true,
                    direction: direction(for: .liveWatts),
                    onSelect: { select(.liveWatts) })
                    .frame(width: 64, alignment: .trailing)
            }
            StatsAppTableHeaderButton(
                // 88pt keeps this longest label (plus its sort arrow) on one
                // line; the row's energy column below mirrors the same width.
                title: "ENERGY / COST",
                column: .energy,
                alignment: .trailing,
                indicatorBeforeLabel: true,
                direction: direction(for: .energy),
                onSelect: { select(.energy) })
                .frame(width: 88, alignment: .trailing)
            StatsAppTableHeaderButton(
                title: columns.detailTitle,
                column: .detail,
                alignment: .trailing,
                indicatorBeforeLabel: true,
                direction: direction(for: .detail),
                onSelect: { select(.detail) })
                .frame(width: columns.detailWidth, alignment: .trailing)
            Color.clear.frame(width: 10, height: 1)
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.trailing, 7)
    }

    /// The chevron follows the column the user picked, never the data-driven
    /// live-watts fallback, so the header can't contradict the click.
    private func direction(for column: AppTableSort.Column) -> AppTableSort.Direction? {
        sort?.column == column ? sort?.direction : nil
    }

    private func select(_ column: AppTableSort.Column) {
        withAnimation(juiceStandardEase) {
            sort = AppTableSort.select(column, from: sort)
        }
    }
}

private struct StatsAppTableHeaderButton: View {
    let title: String
    let column: AppTableSort.Column
    let alignment: Alignment
    let indicatorBeforeLabel: Bool
    /// `nil` when the table is not sorted by this column.
    let direction: AppTableSort.Direction?
    let onSelect: () -> Void

    @State private var hovering = false

    private var foregroundStyle: HierarchicalShapeStyle {
        direction == nil ? .tertiary : .primary
    }

    private var textAlignment: TextAlignment {
        alignment == .leading ? .leading : .trailing
    }

    private var helpText: String {
        guard let direction else { return "Sort by \(title)" }
        return direction == AppTableSort.naturalDirection(for: column)
            ? "Reverse \(title) sort"
            : "Clear \(title) sort"
    }

    /// The direction the indicator renders: the active sort, or a preview of
    /// the natural direction while hovering an unsorted column.
    private var displayedDirection: AppTableSort.Direction? {
        direction ?? (hovering ? AppTableSort.naturalDirection(for: column) : nil)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 3) {
                if displayedDirection != nil, indicatorBeforeLabel {
                    sortIndicator
                }
                Text(title)
                    .multilineTextAlignment(textAlignment)
                    // Column titles stay on one line, shrinking slightly
                    // rather than wrapping if a label ever outgrows its column.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if displayedDirection != nil, !indicatorBeforeLabel {
                    sortIndicator
                }
            }
            // The hover pill hugs the label (negative padding grows it without
            // shifting the text off its column alignment); the full-width frame
            // below only widens the click target, so it must not carry the fill.
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                    .padding(-3))
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityValue(direction.map { $0 == .ascending ? "Ascending" : "Descending" }
            ?? "Not sorted")
    }

    private var sortIndicator: some View {
        Image(systemName: displayedDirection == .ascending
            ? "arrow.up"
            : "arrow.down")
            .font(.system(size: 7.5, weight: .bold))
            // Dimmed while previewing on hover, full strength once active.
            .opacity(direction == nil ? 0.45 : 1)
    }
}

/// The shared left pane around every Stats app table. Modes provide their own
/// loading, empty, and summary content without duplicating pane typography,
/// column labels, spacing, or padding.
struct StatsAppTablePane<Content: View, Summary: View>: View {
    let title: String
    let showsLiveActivity: Bool
    let columns: StatsAppTableColumns
    @Binding private var sort: AppTableSort?
    @Binding private var query: String

    private let content: Content
    private let summary: Summary

    init(
        title: String,
        showsLiveActivity: Bool,
        columns: StatsAppTableColumns,
        sort: Binding<AppTableSort?>,
        query: Binding<String>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder summary: () -> Summary
    ) {
        self.title = title
        self.showsLiveActivity = showsLiveActivity
        self.columns = columns
        _sort = sort
        _query = query
        self.content = content()
        self.summary = summary()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                if showsLiveActivity {
                    LiveHint()
                }
                Spacer()
                StatsAppSearchField(query: $query)
            }

            StatsAppTableHeader(columns: columns, sort: $sort)
            content
            summary
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

/// Shared disclosure control for every "drawing power now" section - the
/// popover's Session and Today live layers and both Stats dashboards. Only the
/// live rows collapse; this header always stays on screen.
struct CollapsibleLiveHeader: View {
    @Binding var isExpanded: Bool
    let appCount: Int
    let totalWatts: Double
    /// The popover labels its cost column here; Stats has no such column.
    var costContext: String? = nil

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
                if isExpanded, let costContext {
                    Text("\(costContext) COST")
                        .foregroundStyle(.tertiary)
                } else if !isExpanded {
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

struct StatsAppTableNoMatches: View {
    let query: String

    var body: some View {
        Text("No apps match \"\(query)\".")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

private struct StatsAppSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Filter apps", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter apps")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear app filter")
                .accessibilityLabel("Clear app filter")
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .frame(width: 180, height: 22)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.18))
        }
        .onExitCommand {
            query = ""
        }
    }
}

/// A single reusable Stats app row. Device-specific code supplies formatted
/// values, while icon, bar, column geometry, live styling, hover affordance,
/// and accessibility behavior remain consistent.
struct StatsAppTableRow: View {
    let appKey: String
    let displayName: String
    let share: Double
    let columns: StatsAppTableColumns
    let liveWattsText: String?
    let energyText: String?
    let costText: String?
    let detailText: String?
    let accessibilityValue: String
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AppIconView(bundleId: appKey, displayName: displayName)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if liveWattsText != nil {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                        }
                        Text(displayName)
                            .font(.callout)
                            .lineLimit(1)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.accentColor.opacity(liveWattsText == nil ? 0.65 : 1))
                                .frame(
                                    width: geometry.size.width
                                        * CGFloat(max(0, min(1, share))))
                        }
                    }
                    .frame(height: 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if columns.showsLiveWatts {
                    Text(liveWattsText ?? "—")
                        .font(liveWattsText == nil ? .callout : .callout.weight(.semibold))
                        .foregroundStyle(liveWattsText == nil ? Color.secondary : Color.green)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                VStack(alignment: .trailing, spacing: 1) {
                    Text(energyText ?? "—")
                        .font(.callout)
                    if let costText {
                        Text(costText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

                Text(detailText ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: columns.detailWidth, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                    .frame(width: 10)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .background(
                liveWattsText == nil ? Color.clear : Color.green.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens app energy details")
    }
}
