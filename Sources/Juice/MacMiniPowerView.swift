import SwiftUI
import Charts
import JuiceCore

let macMiniPowerRanges: [EnergyRange] = [.today, .week, .allTime]

extension EnergyRange {
    var macMiniPickerLabel: String {
        switch self {
        case .today: return "Today"
        case .week: return "1W"
        case .allTime: return "All"
        default: return pickerLabel
        }
    }

    func macMiniWindowStart(
        now: Date,
        recordingSince: Date?,
        calendar: Calendar
    ) -> Date {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)
                ?? now.addingTimeInterval(-6 * 24 * 3600)
            return calendar.startOfDay(for: sixDaysAgo)
        case .allTime:
            return recordingSince ?? now
        default:
            return calendar.startOfDay(for: now)
        }
    }

    func macMiniBucketDuration(windowStart: Date, now: Date) -> TimeInterval {
        switch self {
        case .today:
            return 60
        case .week:
            return 15 * 60
        case .allTime:
            let duration = now.timeIntervalSince(windowStart)
            if duration <= 31 * 24 * 3600 { return 60 * 60 }
            if duration <= 180 * 24 * 3600 { return 6 * 60 * 60 }
            return 24 * 60 * 60
        default:
            return 60 * 60
        }
    }

    func macMiniAxisLabel(_ date: Date) -> String {
        switch self {
        case .today:
            return date.formatted(.dateTime.hour())
        case .week:
            return date.formatted(.dateTime.weekday(.abbreviated))
        case .allTime:
            return date.formatted(.dateTime.month(.abbreviated).day())
        default:
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

struct MacMiniPowerDashboardData: Sendable {
    var summary: SystemPowerSummary
    var buckets: [SystemPowerBucket]
    var recordingSince: Date?
    var bucketDuration: TimeInterval
    var appTotals: [StoredSystemAppEnergyTotal]
}

enum MacMiniPowerDataLoader {
    static func load(
        store: JuiceStore,
        range: EnergyRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> MacMiniPowerDashboardData {
        let recordingSince = try store.earliestSystemPowerSampleDate()
        let start = range.macMiniWindowStart(
            now: now,
            recordingSince: recordingSince,
            calendar: calendar)
        let bucketDuration = range.macMiniBucketDuration(
            windowStart: start,
            now: now)
        let samples = try store.systemPowerSamples(since: start, until: now)
        // App energy is persisted in hour-aligned buckets. All Time can begin
        // at an arbitrary minute, so include the bucket containing that first
        // sample; it contains no energy from before Juice started recording.
        let appStart = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        return MacMiniPowerDashboardData(
            summary: SystemPowerAnalytics.summary(
                samples: samples,
                windowStart: start,
                windowEnd: now),
            buckets: SystemPowerAnalytics.buckets(
                samples: samples,
                windowStart: start,
                windowEnd: now,
                bucketDuration: bucketDuration),
            recordingSince: recordingSince,
            bucketDuration: bucketDuration,
            appTotals: try store.systemAppEnergyTotals(since: appStart, until: now))
    }
}

struct MacMiniPowerChartPoint: Identifiable {
    var id: Date { bucket.start }
    var bucket: SystemPowerBucket
    var segment: Int
}

enum MacMiniPowerChartSegments {
    static func points(
        _ buckets: [SystemPowerBucket],
        bucketDuration: TimeInterval
    ) -> [MacMiniPowerChartPoint] {
        var segment = 0
        var previous: Date?
        return buckets.map { bucket in
            if let previous,
               bucket.start.timeIntervalSince(previous) > bucketDuration * 1.5 {
                segment += 1
            }
            previous = bucket.start
            return MacMiniPowerChartPoint(bucket: bucket, segment: segment)
        }
    }
}

/// Server-oriented Mac mini dashboard: a live reading plus persisted,
/// gap-aware power and energy history for Today, Week, and All recorded time.
struct MacMiniPowerView: View {
    @ObservedObject private var live = LivePowerCoordinator.shared
    @ObservedObject private var helper = HelperRegistrationController.shared

    let store: JuiceStore?
    let refreshGeneration: Int

    @State private var consumerID = UUID()
    @State private var range: EnergyRange = .today
    @State private var dashboard: MacMiniPowerDashboardData?
    @State private var loadError: String?
    @State private var historyApps: [AppEnergy] = []
    @State private var historyOrigin: DataOrigin = .loading
    @State private var historyError: String?
    @State private var loadedAppRange: EnergyRange?

    private var apps: [AppEnergy] { historyApps }

    private var appOrigin: DataOrigin { historyOrigin }

    private var appError: String? { historyError }

    private var serverHybrid: HybridTodayList? {
        guard let reading = live.reading else { return nil }
        let energyByKey = Dictionary(
            apps.map { ($0.bundleId, $0) },
            uniquingKeysWith: { first, _ in first })
        let active = visibleLiveApps(in: reading).map { app in
            HybridTodayList.ActiveApp(
                appKey: app.appKey,
                displayName: app.displayName,
                watts: app.watts,
                todayWh: energyByKey[app.appKey]?.energyWh,
                todayCpuHours: nil)
        }
        let activeKeys = Set(active.map(\.appKey))
        return HybridTodayList(
            active: active,
            earlier: apps.filter { !activeKeys.contains($0.bundleId) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            liveHeader

            Picker("Power history", selection: $range) {
                ForEach(macMiniPowerRanges, id: \.self) { range in
                    Text(range.macMiniPickerLabel).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                Text("Apps by energy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if live.status == .sampling || live.status == .warmingUp {
                    LiveHint()
                }
                Spacer()
            }

            TopAppsView(
                apps: apps,
                range: $range,
                origin: appOrigin,
                detailOrigin: .server,
                ranges: macMiniPowerRanges,
                showsRangePicker: false,
                showsLiveAcrossRanges: true,
                hybrid: serverHybrid,
                batteryWatts: nil,
                onAC: true,
                totalAppWatts: live.reading?.totalAppWatts,
                session: nil)
            appEnergyStatus
            if let reading = live.reading {
                Text(serverPowerBreakdownText(
                    reading,
                    includesMeteredTotal: false))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            if let dashboard {
                summaryGrid(dashboard.summary)
                powerChart(dashboard)
                monitoringFooter(dashboard)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ProgressView("Loading server power history…")
                    .controlSize(.small)
            }
        }
        .task(id: LoadRequest(range: range, generation: refreshGeneration)) {
            syncLiveAttachment()
            await loadDashboard()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await loadDashboard()
            }
        }
        .onAppear {
            syncLiveAttachment()
        }
        .onDisappear {
            live.setAttached(false, for: .popover(consumerID))
        }
    }

    private struct LoadRequest: Hashable {
        var range: EnergyRange
        var generation: Int
    }

    @ViewBuilder
    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mac mini server")
                    .font(.headline)
                Spacer()
                if live.status == .sampling {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch live.status {
            case .sampling:
                if let watts = live.reading?.totalMeteredWatts {
                    Text(liveWattsText(watts))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityLabel("Current power")
                        .accessibilityValue(liveWattsText(watts))
                    Text("Current CPU, GPU, and Neural Engine draw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Measuring current power…")
                        .controlSize(.small)
                }
            case .warmingUp:
                ProgressView("Measuring current power…")
                    .controlSize(.small)
            case .helperOutdated:
                Text("Current power needs the updated helper. Restart Juice to update it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .unavailable(let message):
                HelperStatusView(
                    controller: helper,
                    queryError: message,
                    onRetryQuery: helper.refresh,
                    purpose: "current power")
            }
        }
    }

    private func summaryGrid(_ summary: SystemPowerSummary) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ],
            spacing: 8
        ) {
            PowerMetricCard(
                title: "AVERAGE LOAD",
                value: summary.averageWatts.map(liveWattsText) ?? "—")
            PowerMetricCard(
                title: "ENERGY USED",
                value: serverEnergyText(summary.energyWh))
            PowerMetricCard(
                title: "PEAK LOAD",
                value: summary.peakWatts.map(liveWattsText) ?? "—")
            PowerMetricCard(
                title: "MONITORED",
                value: coverageText(summary))
        }
    }

    @ViewBuilder
    private func powerChart(_ dashboard: MacMiniPowerDashboardData) -> some View {
        let buckets = dashboard.buckets
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Average load")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("Stored every minute")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if buckets.count < 2 {
                Text("Collecting power history—check back in a few minutes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                let points = MacMiniPowerChartSegments.points(
                    buckets,
                    bucketDuration: dashboard.bucketDuration)
                let upperBound = max(1, (buckets.map(\.peakWatts).max() ?? 1) * 1.15)
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", point.bucket.start),
                        y: .value("Average watts", point.bucket.averageWatts),
                        series: .value("Continuous recording", point.segment)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.green.opacity(0.28), .green.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom))

                    LineMark(
                        x: .value("Time", point.bucket.start),
                        y: .value("Average watts", point.bucket.averageWatts),
                        series: .value("Continuous recording", point.segment)
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...upperBound)
                .chartXScale(
                    domain: dashboard.summary.windowStart...dashboard.summary.windowEnd)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                            .foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let watts = value.as(Double.self) {
                                Text(chartWattsText(watts))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(range.macMiniAxisLabel(date))
                            }
                        }
                    }
                }
                .frame(height: 118)
                .accessibilityLabel("Average server power history")
            }
        }
    }

    @ViewBuilder
    private func monitoringFooter(_ dashboard: MacMiniPowerDashboardData) -> some View {
        let summary = dashboard.summary
        VStack(alignment: .leading, spacing: 3) {
            if let average = summary.averageWatts {
                let monthlyKWh = average * 24 * 30 / 1000
                Text(String(
                    format: "At this average load: about %.1f kWh per 30 days",
                    monthlyKWh))
            }
            if summary.coverageFraction < 0.98 {
                Text("Energy totals cover only recorded periods; gaps are not estimated.")
                    .foregroundStyle(.orange)
            }
            if let recordingSince = dashboard.recordingSince {
                Text("Recording since \(recordingSince.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func loadDashboard() async {
        guard let store else {
            dashboard = nil
            loadError = "Power history is unavailable because the local store could not be opened."
            historyApps = []
            historyOrigin = .unavailable
            historyError = loadError
            loadedAppRange = range
            return
        }

        let now = Date()
        let requestedRange = range
        if loadedAppRange != requestedRange {
            historyOrigin = .loading
            historyApps = []
            historyError = nil
        }
        do {
            let result = try await Task.detached {
                try MacMiniPowerDataLoader.load(
                    store: store,
                    range: requestedRange,
                    now: now)
            }.value
            guard !Task.isCancelled, requestedRange == range else { return }
            dashboard = result
            loadError = nil
            historyApps = result.appTotals.map {
                AppEnergy(
                    bundleId: $0.appKey,
                    displayName: $0.displayName,
                    energyWh: $0.energyWh,
                    cpuHours: $0.activeDuration / 3600)
            }
            historyOrigin = .server
            historyError = nil
            loadedAppRange = requestedRange
        } catch {
            guard !Task.isCancelled, requestedRange == range else { return }
            dashboard = nil
            loadError = "Could not load power history: \(error.localizedDescription)"
            historyApps = []
            historyOrigin = .unavailable
            historyError = error.localizedDescription
            loadedAppRange = requestedRange
        }
    }

    private func syncLiveAttachment() {
        live.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(consumerID))
    }

    @ViewBuilder
    private var appEnergyStatus: some View {
        if appOrigin == .loading {
            ProgressView("Loading app energy…")
                .controlSize(.small)
        } else if appOrigin == .unavailable {
            HelperStatusView(
                controller: helper,
                queryError: appError,
                onRetryQuery: retryApps,
                purpose: "app energy")
        } else if apps.isEmpty && (serverHybrid?.active.isEmpty ?? true) {
            Text("Collecting app energy—live apps appear as soon as they draw measurable power.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if appOrigin == .server {
            Text("App energy is recorded directly every minute. Click an app for details.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func retryApps() {
        Task { await loadDashboard() }
    }

    private func coverageText(_ summary: SystemPowerSummary) -> String {
        let percent = Int((summary.coverageFraction * 100).rounded())
        if range == .today {
            let hours = summary.coveredDuration / 3600
            return String(format: "%.1f h · %d%%", hours, percent)
        }
        return "\(percent)%"
    }
}

private struct PowerMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
