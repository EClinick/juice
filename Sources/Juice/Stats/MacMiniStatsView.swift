import SwiftUI
import Charts
import JuiceCore

/// Full server dashboard. Unlike the battery Stats window, current app watts
/// remain visible for every selected history range.
struct MacMiniStatsView: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                appPane
                    .frame(minWidth: 500)
                Divider()
                powerPane
                    .frame(minWidth: 320)
            }

            Divider()
            footer
        }
        .frame(
            minWidth: Self.minimumContentWidth,
            minHeight: Self.minimumContentHeight)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac mini Stats")
                        .font(.title2.weight(.semibold))
                    Text("Current app watts and \(rangeDescription) energy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
            }

            Picker("Server history range", selection: $range) {
                ForEach(macMiniPowerRanges, id: \.self) {
                    Text($0.macMiniPickerLabel).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    private struct LoadRequest: Hashable {
        var range: EnergyRange
        var retryGeneration: Int
    }

    private var appPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apps using power")
                    .font(.headline)
                if live.status == .sampling || live.status == .warmingUp {
                    LiveHint()
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text("APP")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("LIVE W")
                    .frame(width: 64, alignment: .trailing)
                Text("ENERGY")
                    .frame(width: 72, alignment: .trailing)
                Text("PEAK W")
                    .frame(width: 64, alignment: .trailing)
                Color.clear.frame(width: 10, height: 1)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)

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

            if let reading = live.reading {
                Text(serverPowerBreakdownText(
                    reading,
                    includesMeteredTotal: true))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func appRow(_ app: AppRow) -> some View {
        Button(action: {
            showDetail(app)
        }, label: {
            appRowLabel(app)
        })
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(
            "\(app.liveWatts.map(liveWattsText) ?? "not live"), \(app.energyWh.map(serverEnergyText) ?? "energy unavailable")")
        .accessibilityHint("Opens app energy details")
    }

    private func appRowLabel(_ app: AppRow) -> some View {
        let isLive = app.liveWatts != nil
        let liveText = app.liveWatts.map(liveWattsText) ?? "—"
        let barFraction = CGFloat(max(0, min(1, (app.energyWh ?? 0) / maxAppEnergy)))
        let rowBackground = isLive ? Color.green.opacity(0.06) : Color.clear

        return HStack(spacing: 10) {
            AppIconView(bundleId: app.appKey, displayName: app.displayName)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isLive {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                    }
                    Text(app.displayName)
                        .font(.callout)
                        .lineLimit(1)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(isLive
                                ? Color.accentColor
                                : Color.accentColor.opacity(0.65))
                            .frame(width: geometry.size.width * barFraction)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(liveText)
                .font(isLive ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(isLive ? Color.green : Color.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)

            Text(app.energyWh.map(serverEnergyText) ?? "—")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)

            Text(app.peakWatts.map(liveWattsText) ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
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
