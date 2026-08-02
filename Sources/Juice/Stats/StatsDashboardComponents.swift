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

    var body: some View {
        HStack(spacing: 10) {
            Text("APP")
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsLiveWatts {
                Text("LIVE W")
                    .frame(width: 64, alignment: .trailing)
            }
            Text("ENERGY / COST")
                .frame(width: 72, alignment: .trailing)
            Text(columns.detailTitle)
                .frame(width: columns.detailWidth, alignment: .trailing)
            Color.clear.frame(width: 10, height: 1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 7)
    }
}

/// The shared left pane around every Stats app table. Modes provide their own
/// loading, empty, and summary content without duplicating pane typography,
/// column labels, spacing, or padding.
struct StatsAppTablePane<Content: View, Summary: View>: View {
    let title: String
    let showsLiveActivity: Bool
    let columns: StatsAppTableColumns

    private let content: Content
    private let summary: Summary

    init(
        title: String,
        showsLiveActivity: Bool,
        columns: StatsAppTableColumns,
        @ViewBuilder content: () -> Content,
        @ViewBuilder summary: () -> Summary
    ) {
        self.title = title
        self.showsLiveActivity = showsLiveActivity
        self.columns = columns
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
            }

            StatsAppTableHeader(columns: columns)
            content
            summary
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
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
                .frame(width: 72, alignment: .trailing)

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
