import SwiftUI
import JuiceCore

struct PopoverView: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject private var updater = UpdateController.shared
    @ObservedObject private var helper = HelperRegistrationController.shared
    /// The app-scoped live-power source of truth, shared with the Stats window
    /// so the two views can never disagree about which apps are live.
    @ObservedObject private var live = LivePowerCoordinator.shared
    @ObservedObject private var batterySession = BatterySessionCoordinator.shared

    private let selector = EnergySourceSelector()

    /// A per-instance live-loop identity. If SwiftUI spins up a second
    /// PopoverView while the first is still unwinding (rapid close/reopen), each
    /// instance owns a distinct token, so the stale instance's teardown detaches
    /// only itself and never the fresh, visible instance.
    @State private var consumerID = UUID()

    @State private var range: EnergyRange
    /// The popover is recreated when opened. Apply the power-aware default once
    /// per presentation, after the immediate battery refresh, without changing
    /// tabs underneath someone who manually chooses another range.
    @State private var didApplyInitialRange = false
    /// Calendar history other than Today. Today reads the coordinator's
    /// published result; Session reads its exact-window coordinator.
    @State private var historyApps: [AppEnergy] = []
    @State private var timeline: [BatterySample] = []
    @State private var timelineAvailability: TimelineAvailability = .loading
    @State private var timelineWindowEnd = Date()
    @State private var historyOrigin: DataOrigin = .loading
    @State private var historyError: String?
    @State private var insights: [Insight] = []
    @State private var historyCoverageDayCount: Int?
    @State private var loadTask: Task<Void, Never>?

    private var replacementAnimation: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    init(model: BatteryViewModel) {
        self.model = model
        _range = State(initialValue: .initialRange(onAC: model.reading?.onAC))
    }

    /// The app-table inputs for the current range: the coordinator's Today
    /// result on ``.today``, the view's own history fetch otherwise.
    private var topApps: [AppEnergy] {
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
        case .today: return live.todayResult?.coverageDayCount
        case .session: return nil
        default: return historyCoverageDayCount
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = model.reading, r.hasBattery {
                HStack {
                    Text("Battery - \(r.percent)%")
                        .font(.headline)
                    Spacer()
                    Text(model.timeRemainingText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if r.onAC {
                        Label(r.isCharging ? String(format: "Charging at %.1f W", abs(r.watts))
                                           : "Plugged in, not charging",
                              systemImage: "powerplug")
                    } else {
                        Label(String(format: "Drawing %.1f W", abs(r.watts)),
                              systemImage: "bolt")
                    }
                    Spacer()
                }
                .font(.callout)

                Divider()

                HStack {
                    if let health = r.healthPercent {
                        Text("Health \(health)%")
                        Text("·")
                    }
                    Text("\(r.cycleCount) cycles")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                // The hybrid's own section captions replace this header line;
                // rendering both would waste a row of the popover's height.
                if !showsLiveAppSections {
                    HStack {
                        Text("Top energy users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if range.usesLivePower,
                           live.status == .sampling || live.status == .warmingUp {
                            LiveHint()
                        }
                        Spacer()
                    }
                }
                TopAppsView(
                    apps: topApps,
                    range: $range,
                    origin: origin,
                    hybrid: range.usesLivePower ? live.hybrid : nil,
                    batteryWatts: model.reading.map { abs($0.watts) },
                    onAC: model.reading?.onAC ?? false,
                    totalAppWatts: range.usesLivePower ? live.reading?.totalAppWatts : nil,
                    session: batterySession.result?.session)
                energyStatus

                Divider()

                Text("Battery level - last 24 h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimelineLegend()
                if timelineAvailability == .unavailable {
                    Text("Battery history is unavailable because the local store could not be opened.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if timeline.isEmpty {
                    Text("Collecting charge history - check back in a few minutes.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ChargeTimelineView(
                        samples: timeline,
                        windowStart: timelineWindowEnd.addingTimeInterval(-24 * 3600),
                        windowEnd: timelineWindowEnd
                    )
                }

                if !insights.isEmpty {
                    Divider()
                    ForEach(insights.prefix(2)) { insight in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: iconName(for: insight.severity))
                                .foregroundStyle(color(for: insight.severity))
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(insight.title).font(.caption.weight(.medium))
                                Text(insight.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("No battery detected.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            if updater.isAvailable {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Toggle("Automatic updates", isOn: Binding(
                            get: { updater.automaticallyUpdates },
                            set: { updater.automaticallyUpdates = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                    }
                    Text("Turn this off to update manually.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
            }

            HStack {
                Button("Refresh") {
                    model.refresh()
                    helper.refresh()
                    loadTask?.cancel()
                    loadTask = Task { await loadEnergy() }
                }
                Button("Stats") {
                    StatsWindowPresenter.shared.show(
                        selector: selector,
                        timelineSource: timelineSource,
                        reading: model.reading
                    )
                }
                Spacer()
                Button("Quit Juice") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            model.refresh()
            helper.refresh()
            applyInitialRange()
            syncDataAttachments()
        }
        .task { await loadEnergy() }
        .onChange(of: range) {
            loadTask?.cancel()
            syncDataAttachments()
            loadTask = Task { await loadTopApps() }
        }
        .onChange(of: helper.readyGeneration) {
            if origin == .unavailable { retryTopApps() }
        }
        // The popover recreates its content on open and tears it down on close.
        .onDisappear {
            live.setAttached(false, for: .popover(consumerID))
            batterySession.setAttached(false, for: .popover(consumerID))
        }
    }

    /// Attaches to the shared live loop while the popover is showing Session or
    /// Today. Idempotent: repeated calls with the same state are absorbed.
    private func syncDataAttachments() {
        live.setAttached(range.usesLivePower, for: .popover(consumerID))
        batterySession.setAttached(range == .session, for: .popover(consumerID))
    }

    private func applyInitialRange() {
        guard !didApplyInitialRange else { return }
        didApplyInitialRange = true
        range = .initialRange(onAC: model.reading?.onAC)
    }

    @ViewBuilder
    private var energyStatus: some View {
        if range.usesLivePower, live.status == .helperOutdated {
            liveStatus.transition(.opacity)
        }

        if origin == .loading {
            ProgressView().controlSize(.small).transition(.opacity)
        } else if origin == .unavailable {
            HelperStatusView(
                controller: helper,
                queryError: energyError,
                onRetryQuery: retryTopApps)
                .transition(.opacity)
        } else if range == .session {
            if batterySession.result?.session == nil {
                Text("No battery session has been recorded yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            } else if batterySession.result?.energyCoverage == .unavailable {
                Text("App energy is no longer available for this session.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if batterySession.result?.energyCoverage == .partial {
                Text("App energy covers only the recent part of this session.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if topApps.isEmpty {
                Text("No app energy was recorded for this session.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(sessionEnergyCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if topApps.isEmpty {
            Text("No app energy was recorded for this period.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        } else if origin == .live, range != .today {
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

        if range != .today, range != .session, origin == .store, !topApps.isEmpty {
            Text("Stored details are summarized by day.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var sessionEnergyCaption: String {
        let total = topApps.reduce(0) { $0 + $1.energyWh }
        let base = String(format: "Apps used %.1f Wh in this session", total)
        if batterySession.result?.session?.isActive == true {
            return "\(base) · recent intervals may take a few minutes to appear."
        }
        return "\(base)."
    }

    @ViewBuilder
    private var liveStatus: some View {
        if case .helperOutdated = live.status {
            Text("Live power needs the updated helper - restart Juice to update it.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    /// Mirrors TopAppsView's condition for rendering a live-first app list.
    private var showsLiveAppSections: Bool {
        range.usesLivePower && !(live.hybrid?.active.isEmpty ?? true)
    }

    private var timelineSource: EnergySource? {
        if let store = JuiceApp.sampler?.store {
            return StoreEnergySource(store: store)
        }
        return nil
    }

    private func loadEnergy() async {
        await loadTopApps()
        // Charge history comes from the local sample store. One captured
        // window end anchors both the store query and the chart's x-domain.
        if let store = JuiceApp.sampler?.store {
            let windowEnd = Date()
            do {
                let timeline = try await StoreEnergySource(store: store)
                    .batteryTimeline(hours: 24, until: windowEnd)
                self.timeline = timeline
                self.timelineWindowEnd = windowEnd
                timelineAvailability = .available
            } catch {
                timelineAvailability = .unavailable
            }
            insights = await InsightsProvider(store: store).currentInsights()
        } else {
            timelineAvailability = .unavailable
        }
    }

    private func iconName(for severity: InsightSeverity) -> String {
        switch severity {
        case .warning: return "exclamationmark.triangle"
        case .notice: return "lightbulb"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: InsightSeverity) -> Color {
        switch severity {
        case .warning: return .orange
        case .notice: return .yellow
        case .info: return .blue
        }
    }

    private func loadTopApps() async {
        // Today is owned and published by the coordinator (one query feeds both
        // the hybrid and its Earlier Today rows), so the view only fetches the
        // historical ranges itself.
        guard range != .today, range != .session else { return }
        // Capture the requested range: if the selection changes while the
        // query is in flight, the stale result must not overwrite the newer
        // selection's data.
        let range = self.range
        withAnimation(replacementAnimation) {
            historyOrigin = .loading
            historyApps = []
            historyError = nil
            historyCoverageDayCount = nil
        }
        let result = await selector.topApps(range: range, limit: 8)
        guard !Task.isCancelled, range == self.range else { return }
        withAnimation(replacementAnimation) {
            historyApps = result.apps
            historyOrigin = result.origin
            historyCoverageDayCount = result.coverageDayCount
            historyError = result.errorDescription
        }
    }

    private func retryTopApps() {
        if range == .today {
            live.refreshTodayNow()
            return
        }
        if range == .session {
            batterySession.refreshNow()
            return
        }
        loadTask?.cancel()
        loadTask = Task { await loadTopApps() }
    }
}
