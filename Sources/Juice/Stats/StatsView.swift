import SwiftUI
import JuiceCore

/// The one Stats page used by both battery Macs and Mac minis. Each mode keeps
/// its own data lifecycle, while the dashboard shell, header, and app table are
/// shared components.
struct StatsView: View {
    private enum Content {
        case battery(
            selector: EnergySourceSelector,
            timelineSource: EnergySource?,
            model: BatteryViewModel)
        case server(store: JuiceStore?)
    }

    static let batteryMinimumContentWidth = BatteryStatsDashboard.minimumContentWidth
    static let batteryMinimumContentHeight = BatteryStatsDashboard.minimumContentHeight
    static let serverMinimumContentWidth = MacMiniStatsDashboard.minimumContentWidth
    static let serverMinimumContentHeight = MacMiniStatsDashboard.minimumContentHeight

    private let content: Content

    init(
        selector: EnergySourceSelector,
        timelineSource: EnergySource?,
        model: BatteryViewModel
    ) {
        content = .battery(
            selector: selector,
            timelineSource: timelineSource,
            model: model)
    }

    init(serverStore: JuiceStore?) {
        content = .server(store: serverStore)
    }

    @ViewBuilder
    var body: some View {
        switch content {
        case let .battery(selector, timelineSource, model):
            BatteryStatsDashboard(
                selector: selector,
                timelineSource: timelineSource,
                model: model)
        case let .server(store):
            MacMiniStatsDashboard(store: store)
        }
    }
}

/// Battery-specific state and data loading for the shared Stats page.
private struct BatteryStatsDashboard: View {
    /// The app rows include fixed-width energy and CPU columns, and live Today
    /// rows add a 64 pt watts column plus its 10 pt spacing. Keep enough room
    /// for an app name instead of letting that column collapse first.
    static let minimumAppTableWidth: CGFloat = 462
    static let minimumTimelineWidth: CGFloat = 280
    static let minimumContentWidth = minimumAppTableWidth + minimumTimelineWidth + 1
    static let minimumContentHeight: CGFloat = 420

    let selector: EnergySourceSelector
    let timelineSource: EnergySource?
    @ObservedObject var model: BatteryViewModel
    @ObservedObject private var helper = HelperRegistrationController.shared
    /// The app-scoped live-power source of truth, shared with the popover so the
    /// two views can never disagree about which apps are live.
    @ObservedObject private var live = LivePowerCoordinator.shared
    @ObservedObject private var batterySession = BatterySessionCoordinator.shared

    /// The charge timeline always covers the last 7 days.
    private static let timelineHours = 24 * 7

    /// A per-instance live-loop identity. The presenter swaps in a new
    /// StatsView on reopen while the old one tears down; distinct tokens mean
    /// the stale instance's teardown detaches only itself, never the fresh
    /// visible instance. `windowWillClose` releases whatever stats token(s)
    /// remain, covering the retained-window `.onDisappear` gap.
    @State private var consumerID = UUID()

    @State private var range: EnergyRange
    @AppStorage(StatsRangeVisibility.storageKey)
    private var rangeVisibilityStorage = StatsRangeVisibility.defaultStorageValue
    @AppStorage(ElectricityCost.pricePerKilowattHourStorageKey)
    private var pricePerKilowattHour = ElectricityCost.defaultPricePerKilowattHour
    @State private var isCustomizingRanges = false
    /// Calendar history other than Today. Today reads the coordinator's
    /// published result; Session reads its exact-window coordinator.
    @State private var historyApps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []
    @State private var timelineAvailability: TimelineAvailability = .loading
    @State private var timelineWindowEnd = Date()
    @State private var refreshedAt = Date()
    @State private var historyOrigin: DataOrigin = .loading
    @State private var historyError: String?
    @State private var historyCoverageDayCount: Int?
    @State private var loadedHistoryRange: EnergyRange?
    @State private var appsRefreshGeneration = 0

    private var replacementAnimation: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    private var visibleRanges: [EnergyRange] {
        StatsRangeVisibility.visibleRanges(from: rangeVisibilityStorage)
    }

    private var showsLivePower: Bool {
        range.usesLivePower(onAC: model.reading?.onAC)
    }

    init(
        selector: EnergySourceSelector,
        timelineSource: EnergySource?,
        model: BatteryViewModel
    ) {
        self.selector = selector
        self.timelineSource = timelineSource
        self.model = model
        _range = State(initialValue: .initialRange(onAC: model.reading?.onAC))
    }

    /// The app-table inputs for the current range: the coordinator's Today
    /// result on ``.today``, the view's own history fetch otherwise.
    private var apps: [AppEnergy] {
        switch range {
        case .session: return batterySession.result?.apps ?? []
        case .today: return live.todayResult?.apps ?? []
        default: return historyApps
        }
    }
    private var origin: DataOrigin {
        switch range {
        case .session: return batterySession.result?.origin ?? .loading
        case .today: return live.todayResult?.origin ?? .loading
        default: return historyOrigin
        }
    }
    private var energyError: String? {
        switch range {
        case .session: return batterySession.result?.errorDescription
        case .today: return live.todayResult?.errorDescription
        default: return historyError
        }
    }
    private var coverageDayCount: Int? {
        switch range {
        case .session: return nil
        case .today: return live.todayResult?.coverageDayCount
        default: return historyCoverageDayCount
        }
    }

    private var totalEnergy: Double {
        max(apps.reduce(0) { $0 + $1.energyWh }, 0.001)
    }

    private func costText(_ wattHours: Double?) -> String? {
        guard let wattHours else { return nil }
        return ElectricityCost.formattedEstimate(
            wattHours: wattHours,
            pricePerKilowattHour: pricePerKilowattHour)
    }

    private func historicalAppRow(_ app: AppEnergy, share: Double) -> some View {
        let cost = costText(app.energyWh)
        let energyAccessibility = String(
            format: "%.1f watt-hours, %.1f CPU-hours",
            app.energyWh,
            app.cpuHours)
        let accessibilityValue = cost.map {
            "\(energyAccessibility), estimated cost \($0)"
        } ?? energyAccessibility

        return StatsAppTableRow(
            appKey: app.bundleId,
            displayName: app.displayName,
            share: share,
            columns: .battery(showsLiveWatts: showsLivePower),
            liveWattsText: nil,
            energyText: String(format: "%.1f Wh", app.energyWh),
            costText: cost,
            detailText: String(format: "%.1f h", app.cpuHours),
            accessibilityValue: accessibilityValue,
            onTap: {
                showAppDetail(
                    appKey: app.bundleId,
                    displayName: app.displayName)
            })
    }

    private func activeAppRow(
        _ app: HybridTodayList.ActiveApp,
        energyWh: Double?,
        cpuHours: Double?,
        share: Double
    ) -> some View {
        let liveText = liveWattsText(app.watts)
        let cost = costText(energyWh)
        var accessibilityValues = [liveText]
        if let energyWh {
            accessibilityValues.append(
                String(format: "%.1f watt-hours", energyWh)
                    + " \(energyContext)")
        }
        if let cost {
            accessibilityValues.append(
                "estimated cost \(cost) \(energyContext)")
        }
        if let cpuHours {
            accessibilityValues.append(
                String(format: "%.1f CPU-hours", cpuHours))
        }

        return StatsAppTableRow(
            appKey: app.appKey,
            displayName: app.displayName,
            share: share,
            columns: .battery(showsLiveWatts: true),
            liveWattsText: liveText,
            energyText: energyWh.map { String(format: "%.1f Wh", $0) },
            costText: cost,
            detailText: cpuHours.map { String(format: "%.1f h", $0) },
            accessibilityValue: accessibilityValues.joined(separator: ", "),
            onTap: {
                showAppDetail(
                    appKey: app.appKey,
                    displayName: app.displayName)
            })
    }

    private func showAppDetail(appKey: String, displayName: String) {
        AppDetailPresenter.shared.show(
            appKey: appKey,
            displayName: displayName,
            range: range,
            origin: origin,
            session: range == .session ? batterySession.result?.session : nil)
    }

    private var energyContext: String {
        switch range {
        case .session: return "for this session"
        case .today: return "today"
        case .threeDays: return "over three days"
        case .week: return "over the last week"
        case .allTime: return "over all recorded time"
        }
    }

    var body: some View {
        StatsDashboardLayout(
            minimumContentWidth: Self.minimumContentWidth,
            minimumAppPaneWidth: Self.minimumAppTableWidth,
            minimumDetailPaneWidth: Self.minimumTimelineWidth,
            minimumContentHeight: Self.minimumContentHeight,
            header: { header },
            appPane: { appTable },
            detailPane: { timelinePane },
            footer: { footer })
        .task(id: AppsLoadRequest(
            range: range,
            refreshGeneration: appsRefreshGeneration)
        ) {
            await loadApps()
        }
        .task {
            await loadTimeline()
            guard !Task.isCancelled else { return }
            refreshedAt = Date()
            // Keep both visible data panes fresh while the window stays open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await loadApps()
                guard !Task.isCancelled else { break }
                await loadTimeline()
                guard !Task.isCancelled else { break }
                refreshedAt = Date()
            }
        }
        .onChange(of: range) {
            syncDataAttachments()
        }
        .onChange(of: model.reading?.onAC) {
            syncDataAttachments()
        }
        .onChange(of: helper.readyGeneration) {
            if origin == .unavailable { retryApps() }
        }
        // Attachment is gated on the two live ranges so the shared 2 s loop
        // stays idle while the window sits on historical ranges.
        .onAppear {
            range = StatsRangeVisibility.preferredRange(
                range,
                from: rangeVisibilityStorage)
            syncDataAttachments()
        }
        .onDisappear {
            live.setAttached(false, for: .stats(consumerID))
            batterySession.setAttached(false, for: .stats(consumerID))
        }
    }

    /// Attaches to the shared live loop for Today, and for Session only while
    /// unplugged. Idempotent: repeated calls with the same state are absorbed.
    private func syncDataAttachments() {
        live.setAttached(
            showsLivePower,
            includesTodayHistory: range == .today,
            for: .stats(consumerID))
        batterySession.setAttached(range == .session, for: .stats(consumerID))
    }

    // MARK: - Header

    private var header: some View {
        StatsDashboardHeader(
            title: "Juice Stats",
            subtitle: rangeSubtitle,
            actions: {
                Button {
                    withAnimation(replacementAnimation) {
                        isCustomizingRanges.toggle()
                    }
                } label: {
                    Label(
                        isCustomizingRanges ? "Done" : "Customize Tabs",
                        systemImage: isCustomizingRanges
                            ? "checkmark"
                            : "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isCustomizingRanges
                    ? "Finish customizing tabs"
                    : "Choose which tabs appear")
            },
            controls: {
                if isCustomizingRanges {
                    rangeSettings
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(spacing: 16) {
                    Picker("Range", selection: $range) {
                        ForEach(visibleRanges, id: \.self) { range in
                            Text(range.pickerLabel).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)

                    Spacer(minLength: 0)
                    ElectricityRateControl()
                }
            })
    }

    private var rangeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Visible tabs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show All") {
                    rangeVisibilityStorage = StatsRangeVisibility.allStorageValue
                }
                .buttonStyle(.plain)
                .font(.caption)
                .disabled(visibleRanges.count == EnergyRange.allCases.count)
            }

            HStack(spacing: 14) {
                ForEach(EnergyRange.allCases, id: \.self) { candidate in
                    Toggle(
                        candidate.rawValue,
                        isOn: visibilityBinding(for: candidate))
                    .toggleStyle(.checkbox)
                    .disabled(
                        visibleRanges.count == 1
                            && visibleRanges.contains(candidate))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func visibilityBinding(for candidate: EnergyRange) -> Binding<Bool> {
        Binding(
            get: { visibleRanges.contains(candidate) },
            set: { isVisible in
                let updated = StatsRangeVisibility.updating(
                    candidate,
                    isVisible: isVisible,
                    in: rangeVisibilityStorage)
                rangeVisibilityStorage = updated

                range = StatsRangeVisibility.preferredRange(range, from: updated)
            })
    }

    private var rangeSubtitle: String {
        switch range {
        case .session:
            if let session = batterySession.result?.session {
                return "\(BatterySessionFormatting.boundary(session)) · \(BatterySessionFormatting.summary(session))"
            }
            return "Energy usage during the current or last battery session"
        case .today: return "Live power and energy usage over the last day"
        case .threeDays: return "Energy usage over the last 3 days"
        case .week: return "Energy usage over the last week"
        case .allTime: return "Energy usage since Juice started recording"
        }
    }

    // MARK: - App table

    private var appTable: some View {
        StatsAppTablePane(
            title: showsLivePower ? "Apps using power" : "Apps by energy",
            showsLiveActivity: showsLivePower
                && (live.status == .sampling || live.status == .warmingUp),
            columns: .battery(showsLiveWatts: showsLivePower),
            content: {
                if range == .today, let hybrid = live.hybrid, !hybrid.active.isEmpty {
                    hybridAppTable(hybrid)
                } else if range == .session,
                          showsLivePower,
                          let hybrid = live.hybrid,
                          !hybrid.active.isEmpty {
                    liveSessionAppTable(hybrid)
                } else {
                    historicalAppTable
                }

                // Today's query status renders here, outside the hybrid-vs-history
                // branch, so a failed or outdated-helper Today fetch is surfaced
                // even while live rows are showing in the hybrid table (which never
                // includes these banners). Mirrors the popover, whose banner sits
                // unconditionally below the app list.
                if range == .today {
                    todayStatusBanner
                } else if range == .session {
                    sessionStatusBanner
                }
            },
            summary: { EmptyView() })
    }

    @ViewBuilder
    private var todayStatusBanner: some View {
        if origin == .unavailable {
            HelperStatusView(queryError: energyError, onRetryQuery: retryApps)
                .transition(.opacity)
        } else if live.status == .helperOutdated {
            Text("Live power needs the updated helper - restart Juice to update it.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var sessionStatusBanner: some View {
        if showsLivePower, live.status == .helperOutdated {
            Text("Live power needs the updated helper - restart Juice to update it.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }

        if origin == .loading {
            ProgressView()
                .controlSize(.small)
                .transition(.opacity)
        } else if origin == .unavailable {
            HelperStatusView(queryError: energyError, onRetryQuery: retryApps)
                .transition(.opacity)
        } else if batterySession.result?.session == nil {
            Text("No battery session has been recorded yet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if batterySession.result?.energyCoverage == .unavailable {
            Text("App energy is no longer available for this session.")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if batterySession.result?.energyCoverage == .partial {
            Text("App energy covers only the recent part of this session.")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if apps.isEmpty {
            Text("No app energy was recorded for this session.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if !apps.isEmpty {
            Text(sessionEnergyCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var sessionEnergyCaption: String {
        let total = apps.reduce(0) { $0 + $1.energyWh }
        let base = String(format: "Apps used %.1f Wh in this session", total)
        if batterySession.result?.session?.isActive == true {
            return "\(base) · recent intervals may take a few minutes to appear."
        }
        return "\(base)."
    }

    @ViewBuilder
    private var historicalAppTable: some View {
        if origin == .loading {
            Group {
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .transition(.opacity)
        } else if apps.isEmpty, origin != .unavailable, range != .session {
            Group {
                Text("No energy data available.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .transition(.opacity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(apps) { app in
                        historicalAppRow(
                            app,
                            share: app.energyWh / totalEnergy)
                    }
                }
                .padding(.trailing, 4)
            }
            .transition(.opacity)
        }

        // Today's unavailable / outdated-helper banners are rendered by
        // ``todayStatusBanner`` at the app-table level so they show whether the
        // hybrid or this historical fallback is on screen; only the non-today
        // captions live here to avoid double-rendering.
        if origin == .unavailable, range != .today, range != .session {
            HelperStatusView(queryError: energyError, onRetryQuery: retryApps)
                .transition(.opacity)
        } else if origin == .live, range != .today, range != .session {
            Text("Live data only (about 3 days) - history store unavailable")
                .font(.caption2)
                .foregroundStyle(.orange)
                .transition(.opacity)
        } else if origin == .store, let days = coverageDayCount {
            Text("History covers \(days) day\(days == 1 ? "" : "s") so far")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        }
        if range != .today, range != .session, origin == .store, !apps.isEmpty {
            Text("Stored details are summarized by day.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The hybrid Today table: an active "drawing power now" section over the
    /// rest of today's energy history, minus the apps shown as active.
    @ViewBuilder
    private func hybridAppTable(_ hybrid: HybridTodayList) -> some View {
        let maxWatts = max(hybrid.active.map(\.watts).max() ?? 0, 0.001)
        let earlierTotal = max(hybrid.earlier.reduce(0) { $0 + $1.energyWh }, 0.001)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        LiveDot()
                        Text("DRAWING POWER NOW")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hybrid.active) { app in
                        activeAppRow(
                            app,
                            energyWh: app.todayWh,
                            cpuHours: app.todayCpuHours,
                            share: app.watts / maxWatts)
                    }
                }

                if !hybrid.earlier.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EARLIER TODAY")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(hybrid.earlier) { app in
                            historicalAppRow(
                                app,
                                share: app.energyWh / earlierTotal)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .transition(.opacity)

        // The coordinator's own unattributed-system figure is shown instead of
        // a battery split.
        if let reading = live.reading {
            Text(String(
                format: "Unattributed system processes: %.1f W", reading.systemWatts))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The Session table uses the same live rows as Today without folding any
    /// of them. Their Wh/CPU columns come from the exact session result, and
    /// the remaining rows show apps that used energy earlier in the session.
    @ViewBuilder
    private func liveSessionAppTable(_ hybrid: HybridTodayList) -> some View {
        let sessionByKey = Dictionary(
            apps.map { ($0.bundleId, $0) },
            uniquingKeysWith: { first, _ in first })
        let activeKeys = Set(hybrid.active.map(\.appKey))
        let earlier = apps.filter { !activeKeys.contains($0.bundleId) }
        let maxWatts = max(hybrid.active.map(\.watts).max() ?? 0, 0.001)
        let earlierTotal = max(earlier.reduce(0) { $0 + $1.energyWh }, 0.001)

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        LiveDot()
                        Text("DRAWING POWER NOW")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hybrid.active) { app in
                        let sessionEnergy = sessionByKey[app.appKey]
                        activeAppRow(
                            app,
                            energyWh: sessionEnergy?.energyWh,
                            cpuHours: sessionEnergy?.cpuHours,
                            share: app.watts / maxWatts)
                    }
                }

                if !earlier.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EARLIER IN SESSION")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(earlier) { app in
                            historicalAppRow(
                                app,
                                share: app.energyWh / earlierTotal)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .transition(.opacity)

        if let reading = live.reading {
            Text(String(
                format: "Unattributed system processes: %.1f W", reading.systemWatts))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Timeline pane

    private var timelinePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery level - last 7 days")
                .font(.caption)
                .foregroundStyle(.secondary)
            TimelineLegend()

            if timelineAvailability == .unavailable {
                Text("Battery history is unavailable because the local store could not be opened.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Spacer()
            } else if timeline.isEmpty {
                Text("Collecting local battery history.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                StatsTimelineChart(
                    samples: timeline,
                    hours: Self.timelineHours,
                    windowEnd: timelineWindowEnd
                )
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let health = model.reading?.healthPercent {
                Text("Health \(health)%")
                Text("·")
            }
            if let cycles = model.reading?.cycleCount {
                Text("\(cycles) cycles")
                Text("·")
            }
            Text("\(footerSource) · refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
    }

    private var footerSource: String {
        if range == .today,
           live.status == .sampling || live.status == .warmingUp {
            return "App energy from macOS powerlog · live power from macOS energy accounting"
        }
        switch origin {
        case .store, .live: return "App energy from macOS powerlog"
        case .server: return "App energy recorded from live macOS energy accounting"
        case .loading, .unavailable:
            return timelineAvailability == .available
                ? "Battery history collected locally"
                : "Live battery status only"
        }
    }

    // MARK: - Loading

    private struct AppsLoadRequest: Hashable {
        var range: EnergyRange
        var refreshGeneration: Int
    }

    private func loadTimeline() async {
        // One captured window end anchors both the store query and the
        // chart's x-domain.
        let windowEnd = Date()
        guard let timelineSource else {
            timelineAvailability = .unavailable
            return
        }
        do {
            let loadedTimeline = try await timelineSource.batteryTimeline(
                hours: Self.timelineHours, until: windowEnd)
            guard !Task.isCancelled else { return }
            self.timeline = loadedTimeline
            self.timelineWindowEnd = windowEnd
            timelineAvailability = .available
        } catch {
            guard !Task.isCancelled else { return }
            timelineAvailability = .unavailable
        }
    }

    private func loadApps() async {
        // Today is owned and published by the coordinator (one query feeds both
        // the hybrid and its Earlier Today rows), so the window only fetches the
        // historical ranges itself.
        guard range != .today, range != .session else { return }
        // Capture the requested range: if the picker changes while the query
        // is in flight, the stale result must not overwrite the newer
        // selection's data.
        let range = self.range
        if HistoricalReloadPolicy.shouldClear(
            loadedRange: loadedHistoryRange,
            requestedRange: range
        ) {
            withAnimation(replacementAnimation) {
                historyOrigin = .loading
                historyApps = []
                historyError = nil
                historyCoverageDayCount = nil
            }
        }
        let result = await selector.topApps(range: range)
        guard !Task.isCancelled, range == self.range else { return }
        withAnimation(replacementAnimation) {
            historyApps = result.apps.sorted { $0.energyWh > $1.energyWh }
            historyOrigin = result.origin
            historyCoverageDayCount = result.coverageDayCount
            historyError = result.errorDescription
            loadedHistoryRange = range
        }
    }

    private func retryApps() {
        if range == .today {
            live.refreshTodayNow()
            return
        }
        if range == .session {
            batterySession.refreshNow()
            return
        }
        appsRefreshGeneration &+= 1
    }
}
