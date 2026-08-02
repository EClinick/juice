import SwiftUI
import Charts
import JuiceCore

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
    @State private var data: MacMiniPowerDashboardData?
    @State private var loadedRange: EnergyRange?
    @State private var loadError: String?
    @State private var refreshedAt = Date()
    @State private var retryGeneration = 0
    @AppStorage(ElectricityCost.pricePerKilowattHourStorageKey)
    private var pricePerKilowattHour = ElectricityCost.defaultPricePerKilowattHour

    private struct AppRow: Identifiable {
        var id: String { appKey }
        var appKey: String
        var displayName: String
        var liveWatts: Double?
        var energyWh: Double?
        var activeDuration: TimeInterval?
        var peakWatts: Double?
    }

    private var appRows: [AppRow] {
        let totals = Dictionary(
            (data?.appTotals ?? []).map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let liveApps = Dictionary(
            visibleLiveApps(in: live.reading)
                .map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let keys = Set(totals.keys).union(liveApps.keys)

        return keys.map { key in
            let total = totals[key]
            let current = liveApps[key]
            return AppRow(
                appKey: key,
                displayName: current?.displayName ?? total?.displayName ?? key,
                liveWatts: current?.watts,
                energyWh: total?.energyWh,
                activeDuration: total?.activeDuration,
                peakWatts: data == nil
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

    private var maxAppEnergy: Double {
        max(appRows.compactMap(\.energyWh).max() ?? 0, 0.001)
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
        .onAppear { attachLive() }
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
                Button("Refresh") {
                    retryGeneration &+= 1
                }
                .controlSize(.small)
            },
            controls: {
                HStack(spacing: 16) {
                    Picker("Server history range", selection: $range) {
                        ForEach(macMiniPowerRanges, id: \.self) {
                            Text($0.macMiniPickerLabel).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 360, alignment: .leading)

                    Spacer(minLength: 0)
                    ElectricityRateControl()
                }
            })
    }

    private struct LoadRequest: Hashable {
        var range: EnergyRange
        var retryGeneration: Int
    }

    private var appPane: some View {
        StatsAppTablePane(
            title: "Apps using power",
            showsLiveActivity: live.status == .sampling || live.status == .warmingUp,
            columns: .server,
            content: {
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if data == nil {
                    ProgressView("Loading app energy history…")
                        .controlSize(.small)
                }

                if appRows.isEmpty {
                    if data != nil {
                        Text("Collecting app energy—live apps appear as soon as they draw measurable power.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(appRows) { app in
                                appRow(app)
                            }
                        }
                        .padding(.trailing, 4)
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

    private func appRow(_ app: AppRow) -> some View {
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

    private func appAccessibilityValue(_ app: AppRow) -> String {
        let liveDescription = app.liveWatts.map(liveWattsText) ?? "not live"
        let energyDescription = app.energyWh
            .map { "\(serverEnergyText($0)) \(accessibilityRangeDescription)" }
            ?? "energy unavailable"
        let base = "\(liveDescription), \(energyDescription)"
        guard let cost = costText(app.energyWh) else { return base }
        return "\(base), estimated cost \(cost) \(accessibilityRangeDescription)"
    }

    private func showDetail(_ app: AppRow) {
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
                    ],
                    spacing: 8
                ) {
                    statsCard(
                        "AVERAGE",
                        data.summary.averageWatts.map(liveWattsText) ?? "—")
                    statsCard("ENERGY", serverEnergyText(data.summary.energyWh))
                    statsCard(
                        "PEAK",
                        data.summary.peakWatts.map(liveWattsText) ?? "—")
                    statsCard("COVERAGE", serverCoverageText(data.summary))
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
