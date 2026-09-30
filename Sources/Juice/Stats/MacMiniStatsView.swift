import SwiftUI
import Charts
import JuiceCore

/// One Mac mini app-table row: a range total joined with the app's live watts.
struct MacMiniAppRow: Identifiable {
    var id: String { appKey }
    var appKey: String
    var displayName: String
    var liveWatts: Double?
    var energyWh: Double?
    var activeDuration: TimeInterval?
    var peakWatts: Double?
}

/// Pure row assembly for the Mac mini app table, kept out of the view so the
/// join, the natural order, and the section split stay testable.
enum MacMiniAppRows {
    /// The table's natural order: live apps first by current watts, then the
    /// rest by energy. `totals` is nil until the range query lands, which is
    /// what suppresses a peak-watts column built from live samples alone.
    static func make(
        totals: [StoredSystemAppEnergyTotal]?,
        liveApps: [AppPowerReading]
    ) -> [MacMiniAppRow] {
        let totalsByKey = Dictionary(
            (totals ?? []).map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let liveByKey = Dictionary(
            liveApps.map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let keys = Set(totalsByKey.keys).union(liveByKey.keys)

        return keys.map { key in
            let total = totalsByKey[key]
            let current = liveByKey[key]
            return MacMiniAppRow(
                appKey: key,
                displayName: current?.displayName ?? total?.displayName ?? key,
                liveWatts: current?.watts,
                energyWh: total?.energyWh,
                activeDuration: total?.activeDuration,
                peakWatts: totals == nil
                    ? nil
                    : max(total?.peakWatts ?? 0, current?.watts ?? 0))
        }
        .sorted {
            switch ($0.liveWatts, $1.liveWatts) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if ($0.energyWh ?? 0) != ($1.energyWh ?? 0) {
                    return ($0.energyWh ?? 0) > ($1.energyWh ?? 0)
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        }
    }

    /// Splits the natural order into the live section and everything else,
    /// preserving the relative order each row arrived in.
    static func sections(
        _ rows: [MacMiniAppRow]
    ) -> (live: [MacMiniAppRow], earlier: [MacMiniAppRow]) {
        (rows.filter { $0.liveWatts != nil }, rows.filter { $0.liveWatts == nil })
    }
}

/// Mac mini-specific state and data loading for the shared Stats page. Unlike
/// battery mode, current app watts remain visible for every history range.
struct MacMiniStatsDashboard: View {
    static let minimumContentWidth: CGFloat = 860
    // The header, chart's 180-point floor, and footer need this much vertical
    // space together. Keeping the old 500-point minimum let an autosaved frame
    // compress the footer below the window's visible content area on reopen.
    static let minimumContentHeight: CGFloat = 560

    let store: JuiceStore?

    @ObservedObject private var live = LivePowerCoordinator.shared
    @State private var consumerID = UUID()
    @State private var range: EnergyRange = .today
    /// `nil` until the user picks a column: the table then keeps its natural
    /// live-first order.
    @State private var appTableSort: AppTableSort?
    @State private var appFilterQuery = ""
    @State private var isLiveSectionExpanded = true
    @State private var data: MacMiniPowerDashboardData?
    @State private var loadedRange: EnergyRange?
    @State private var loadError: String?
    @State private var refreshedAt = Date()
    @State private var retryGeneration = 0
    @AppStorage(StatsRangeVisibility.macMiniStorageKey)
    private var rangeVisibilityStorage = StatsRangeVisibility.macMiniDefaultStorageValue
    @AppStorage(ElectricityCost.pricePerKilowattHourStorageKey)
    private var pricePerKilowattHour = ElectricityCost.defaultPricePerKilowattHour
    @State private var isCustomizingRanges = false

    private var visibleRanges: [EnergyRange] {
        StatsRangeVisibility.visibleRanges(
            from: rangeVisibilityStorage,
            availableRanges: macMiniPowerRanges,
            fallbackRanges: macMiniPowerRanges)
    }

    private func costText(_ wattHours: Double?) -> String? {
        guard let wattHours else { return nil }
        return ElectricityCost.formattedEstimate(
            wattHours: wattHours,
            pricePerKilowattHour: pricePerKilowattHour)
    }

    var body: some View {
        StatsDashboardLayout(
            minimumContentWidth: Self.minimumContentWidth,
            minimumAppPaneWidth: 500,
            minimumDetailPaneWidth: 320,
            minimumContentHeight: Self.minimumContentHeight,
            header: { header },
            appPane: { appPane },
            detailPane: { powerPane },
            footer: { footer })
        .task(id: LoadRequest(range: range, retryGeneration: retryGeneration)) {
            attachLive()
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        .onAppear {
            range = preferredVisibleRange()
            attachLive()
        }
        .onChange(of: rangeVisibilityStorage) {
            range = preferredVisibleRange()
        }
        .onDisappear {
            live.setAttached(false, for: .stats(consumerID))
        }
    }

    private var header: some View {
        StatsDashboardHeader(
            title: "Mac mini Stats",
            subtitle: "Current app watts and \(rangeDescription) energy",
            actions: {
                if let watts = live.reading?.totalMeteredWatts {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(liveWattsText(watts))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                        Text("LIVE TOTAL")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                StatsRangeCustomizationButton(
                    isCustomizing: $isCustomizingRanges)
                Button("Refresh") {
                    retryGeneration &+= 1
                }
                .controlSize(.small)
            },
            controls: {
                if isCustomizingRanges {
                    StatsRangeSettings(
                        availableRanges: macMiniPowerRanges,
                        fallbackRanges: macMiniPowerRanges,
                        selection: $range,
                        storageValue: $rangeVisibilityStorage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                StatsRangePickerRow(
                    title: "Server history range",
                    selection: $range,
                    ranges: visibleRanges,
                    pickerWidth: 360,
                    label: \.macMiniPickerLabel)
            })
    }

    private func preferredVisibleRange() -> EnergyRange {
        StatsRangeVisibility.preferredRange(
            range,
            from: rangeVisibilityStorage,
            availableRanges: macMiniPowerRanges,
            fallbackRanges: macMiniPowerRanges)
    }

    private struct LoadRequest: Hashable {
        var range: EnergyRange
        var retryGeneration: Int
    }

    private var appPane: some View {
        let allRows = MacMiniAppRows.make(
            totals: data?.appTotals,
            liveApps: visibleLiveApps(in: live.reading))
        let sections = MacMiniAppRows.sections(allRows)
        let liveRows = sortedRows(sections.live)
        let earlierRows = sortedRows(sections.earlier)
        // The energy bars stay comparable while a filter is active, so the
        // maximum comes from every row rather than the visible ones.
        let maxAppEnergy = max(allRows.compactMap(\.energyWh).max() ?? 0, 0.001)

        return StatsAppTablePane(
            title: "Apps using power",
            showsLiveActivity: live.status == .sampling || live.status == .warmingUp,
            columns: .server,
            sort: $appTableSort,
            query: $appFilterQuery,
            content: {
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if data == nil {
                    ProgressView("Loading app energy history…")
                        .controlSize(.small)
                }

                if allRows.isEmpty {
                    if data != nil {
                        Text("Collecting app energy—live apps appear as soon as they draw measurable power.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else if liveRows.isEmpty, earlierRows.isEmpty {
                    StatsAppTableNoMatches(query: appFilterQuery)
                    Spacer()
                } else {
                    ScrollView {
                        // One lazy stack rather than a stack per section, so a
                        // long history list still builds its rows on demand.
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if !liveRows.isEmpty {
                                CollapsibleLiveHeader(
                                    isExpanded: $isLiveSectionExpanded,
                                    appCount: liveRows.count,
                                    totalWatts: liveRows.reduce(0) {
                                        $0 + ($1.liveWatts ?? 0)
                                    })
                                if isLiveSectionExpanded {
                                    ForEach(liveRows) { app in
                                        appRow(app, maxAppEnergy: maxAppEnergy)
                                    }
                                }
                            }

                            if !earlierRows.isEmpty {
                                // Without a live section the table is a single
                                // flat list, which needs no section label.
                                if !sections.live.isEmpty {
                                    Text("EARLIER")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                                ForEach(earlierRows) { app in
                                    appRow(app, maxAppEnergy: maxAppEnergy)
                                }
                            }
                        }
                        .padding(.trailing, 4)
                        .animation(
                            juiceStandardEase,
                            value: liveRows.map(\.id) + earlierRows.map(\.id))
                    }
                }
            },
            summary: {
                if let reading = live.reading {
                    Text(serverPowerBreakdownText(
                        reading,
                        includesMeteredTotal: true))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            })
    }

    /// Sorting and filtering run per section so each keeps its own ranking.
    private func sortedRows(_ rows: [MacMiniAppRow]) -> [MacMiniAppRow] {
        AppTableSort.apply(
            appTableSort,
            to: rows,
            query: appFilterQuery
        ) { app in
            AppTableSortValues(
                stableID: app.appKey,
                displayName: app.displayName,
                liveWatts: app.liveWatts,
                energyWh: app.energyWh,
                // PEAK W renders through liveWattsText, so it sorts at the same
                // displayed precision as LIVE W to avoid same-value row swaps.
                detail: app.peakWatts.map(displayedLiveWatts))
        }
    }

    private func appRow(_ app: MacMiniAppRow, maxAppEnergy: Double) -> some View {
        StatsAppTableRow(
            appKey: app.appKey,
            displayName: app.displayName,
            share: (app.energyWh ?? 0) / maxAppEnergy,
            columns: .server,
            liveWattsText: app.liveWatts.map(liveWattsText),
            energyText: app.energyWh.map(serverEnergyText),
            costText: costText(app.energyWh),
            detailText: app.peakWatts.map(liveWattsText),
            accessibilityValue: appAccessibilityValue(app),
            onTap: { showDetail(app) })
    }

    private func appAccessibilityValue(_ app: MacMiniAppRow) -> String {
        let liveDescription = app.liveWatts.map(liveWattsText) ?? "not live"
        let energyDescription = app.energyWh
            .map { "\(serverEnergyText($0)) \(accessibilityRangeDescription)" }
            ?? "energy unavailable"
        let base = "\(liveDescription), \(energyDescription)"
        guard let cost = costText(app.energyWh) else { return base }
        return "\(base), estimated cost \(cost) \(accessibilityRangeDescription)"
    }

    private func showDetail(_ app: MacMiniAppRow) {
        AppDetailPresenter.shared.show(
            appKey: app.appKey,
            displayName: app.displayName,
            range: range,
            origin: .server)
    }

    private var powerPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server power")
                .font(.headline)

            if let data {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    statsCard(
                        "AVERAGE",
                        data.summary.averageWatts.map(liveWattsText) ?? "—")
                    statsCard("ENERGY", serverEnergyText(data.summary.energyWh))
                    statsCard(
                        "EST. COST",
                        costText(data.summary.energyWh) ?? "Set kWh price")
                        .help(
                            "Estimated from total metered energy in the selected "
                            + "range using the current kWh price.")
                    statsCard(
                        "PEAK",
                        data.summary.peakWatts.map(liveWattsText) ?? "—")
                    statsCard(
                        "MONITORED",
                        serverActiveDurationText(
                            data.summary.coveredDuration / 3600)
                            + " · " + serverCoverageText(data.summary))
                        .help(
                            "Time with metered power samples in the selected "
                            + "range and the percentage of that range covered.")
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        statsCard(
                            "SYSTEM UPTIME",
                            systemUptimeText(ProcessInfo.processInfo.systemUptime))
                    }
                    .help(
                        "Time since the last system restart. This is independent "
                        + "of the selected Stats range and estimated cost.")
                }
                statsChart(data)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ProgressView("Loading server history…")
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func statsCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statsChart(_ data: MacMiniPowerDashboardData) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Average load")
                .font(.caption)
                .foregroundStyle(.secondary)
            if data.buckets.isEmpty {
                Text("Collecting server power history.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                let points = MacMiniPowerChartSegments.points(
                    data.buckets,
                    bucketDuration: data.bucketDuration)
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", point.bucket.start),
                        y: .value("Average watts", point.bucket.averageWatts),
                        series: .value("Continuous recording", point.segment))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.green.opacity(0.25), .green.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom))
                    LineMark(
                        x: .value("Time", point.bucket.start),
                        y: .value("Average watts", point.bucket.averageWatts),
                        series: .value("Continuous recording", point.segment))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXScale(
                    domain: data.summary.windowStart...data.summary.windowEnd,
                    range: .plotDimension(padding: 10))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(range.macMiniAxisLabel(date))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let watts = value.as(Double.self) {
                                Text(chartWattsText(watts))
                            }
                        }
                    }
                }
                .frame(minHeight: 180)
                .accessibilityLabel("Server power history")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Direct one-minute app and system energy accounting")
            if let recordingSince = data?.recordingSince {
                Text("·")
                Text("recording since \(recordingSince.formatted(date: .abbreviated, time: .shortened))")
            }
            Spacer()
            Text("refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
    }

    private var rangeDescription: String {
        switch range {
        case .today: return "today's"
        case .week: return "the last week's"
        case .allTime: return "all recorded"
        default: return range.rawValue.lowercased()
        }
    }

    private var accessibilityRangeDescription: String {
        switch range {
        case .session: return "for this session"
        case .today: return "today"
        case .threeDays: return "over the last three days"
        case .week: return "over the last week"
        case .allTime: return "over all recorded time"
        }
    }

    private func attachLive() {
        live.setAttached(
            true,
            includesTodayHistory: false,
            for: .stats(consumerID))
    }

    private func load() async {
        let requestedRange = range
        if loadedRange != requestedRange {
            data = nil
            loadError = nil
        }
        guard let store else {
            data = nil
            loadError = "The local server history store is unavailable."
            return
        }
        let now = Date()
        do {
            let loadTask = Task.detached {
                try MacMiniPowerDataLoader.load(
                    store: store,
                    range: requestedRange,
                    now: now)
            }
            let loaded = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            guard !Task.isCancelled, requestedRange == range else { return }
            data = loaded
            loadedRange = requestedRange
            loadError = nil
            refreshedAt = now
        } catch {
            guard !Task.isCancelled, requestedRange == range else { return }
            if loadedRange != requestedRange {
                data = nil
            }
            loadError = error.localizedDescription
        }
    }

    private func serverCoverageText(_ summary: SystemPowerSummary) -> String {
        "\(Int((summary.coverageFraction * 100).rounded()))%"
    }
}
