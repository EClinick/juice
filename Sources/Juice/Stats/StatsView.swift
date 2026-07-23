import SwiftUI
import AppKit
import JuiceCore

/// The standalone Stats window content: a full per-app energy table alongside a
/// 7-day charge timeline, with a battery-health footer.
struct StatsView: View {
    /// The app rows include fixed-width energy and CPU columns, and live Today
    /// rows add a 60 pt watts column plus its 10 pt spacing. Keep enough room
    /// for an app name instead of letting that column collapse first.
    static let minimumAppTableWidth: CGFloat = 462
    static let minimumTimelineWidth: CGFloat = 280
    static let minimumContentWidth = minimumAppTableWidth + minimumTimelineWidth + 1
    static let minimumContentHeight: CGFloat = 420

    let selector: EnergySourceSelector
    let timelineSource: EnergySource?
    let reading: BatteryReading?
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
    @State private var loadTask: Task<Void, Never>?

    private var replacementAnimation: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    init(
        selector: EnergySourceSelector,
        timelineSource: EnergySource?,
        reading: BatteryReading?
    ) {
        self.selector = selector
        self.timelineSource = timelineSource
        self.reading = reading
        _range = State(initialValue: .initialRange(onAC: reading?.onAC))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                appTable
                    .frame(minWidth: Self.minimumAppTableWidth)
                Divider()
                timelinePane
                    .frame(minWidth: Self.minimumTimelineWidth)
            }

            Divider()
            footer
        }
        .frame(
            minWidth: Self.minimumContentWidth,
            minHeight: Self.minimumContentHeight
        )
        .task {
            await load()
            // Keep the timeline fresh while the window stays open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await loadTimeline()
            }
        }
        .onChange(of: range) {
            loadTask?.cancel()
            syncDataAttachments()
            loadTask = Task { await loadApps() }
        }
        .onChange(of: helper.readyGeneration) {
            if origin == .unavailable { retryApps() }
        }
        // Attachment is gated on the two live ranges so the shared 2 s loop
        // stays idle while the window sits on historical ranges.
        .onAppear { syncDataAttachments() }
        .onDisappear {
            live.setAttached(false, for: .stats(consumerID))
            batterySession.setAttached(false, for: .stats(consumerID))
        }
    }

    /// Attaches to the shared live loop while the window is showing Session or
    /// Today. Idempotent: repeated calls with the same state are absorbed.
    private func syncDataAttachments() {
        live.setAttached(
            range.usesLivePower,
            includesTodayHistory: range == .today,
            for: .stats(consumerID))
        batterySession.setAttached(range == .session, for: .stats(consumerID))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Juice Stats")
                        .font(.title2.weight(.semibold))
                    Text(rangeSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Range", selection: $range) {
                ForEach(EnergyRange.allCases, id: \.self) { range in
                    Text(range.pickerLabel).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
        }
        .padding(16)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Apps by energy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if range.usesLivePower,
                   live.status == .sampling || live.status == .warmingUp {
                    LiveHint()
                }
                Spacer()
            }

            if range == .today, let hybrid = live.hybrid, !hybrid.active.isEmpty {
                hybridAppTable(hybrid)
            } else if range == .session, let hybrid = live.hybrid, !hybrid.active.isEmpty {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
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
        if live.status == .helperOutdated {
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
                        StatsAppRow(
                            app: app,
                            share: app.energyWh / totalEnergy,
                            onTap: {
                                AppDetailPresenter.shared.show(
                                    appKey: app.bundleId,
                                    displayName: app.displayName,
                                    range: range,
                                    origin: origin,
                                    session: range == .session ? batterySession.result?.session : nil
                                )
                            })
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
                        StatsActiveAppRow(
                            app: app,
                            energyWh: app.todayWh,
                            cpuHours: app.todayCpuHours,
                            share: app.watts / maxWatts,
                            onTap: {
                                AppDetailPresenter.shared.show(
                                    appKey: app.appKey,
                                    displayName: app.displayName,
                                    range: range,
                                    origin: origin)
                            })
                    }
                }

                if !hybrid.earlier.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EARLIER TODAY")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(hybrid.earlier) { app in
                            StatsAppRow(
                                app: app,
                                share: app.energyWh / earlierTotal,
                                onTap: {
                                    AppDetailPresenter.shared.show(
                                        appKey: app.bundleId,
                                        displayName: app.displayName,
                                        range: range,
                                        origin: origin)
                                })
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .transition(.opacity)

        // The Stats window's BatteryReading is a stale snapshot, so the model's
        // own unattributed-system figure is shown instead of a battery split.
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
                        StatsActiveAppRow(
                            app: app,
                            energyWh: sessionEnergy?.energyWh,
                            cpuHours: sessionEnergy?.cpuHours,
                            share: app.watts / maxWatts,
                            onTap: {
                                AppDetailPresenter.shared.show(
                                    appKey: app.appKey,
                                    displayName: app.displayName,
                                    range: .session,
                                    origin: origin,
                                    session: batterySession.result?.session)
                            })
                    }
                }

                if !earlier.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EARLIER IN SESSION")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(earlier) { app in
                            StatsAppRow(
                                app: app,
                                share: app.energyWh / earlierTotal,
                                onTap: {
                                    AppDetailPresenter.shared.show(
                                        appKey: app.bundleId,
                                        displayName: app.displayName,
                                        range: .session,
                                        origin: origin,
                                        session: batterySession.result?.session)
                                })
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
            if let health = reading?.healthPercent {
                Text("Health \(health)%")
                Text("·")
            }
            if let cycles = reading?.cycleCount {
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
        case .loading, .unavailable:
            return timelineAvailability == .available
                ? "Battery history collected locally"
                : "Live battery status only"
        }
    }

    // MARK: - Loading

    private func load() async {
        await loadApps()
        await loadTimeline()
        refreshedAt = Date()
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
            let timeline = try await timelineSource.batteryTimeline(
                hours: Self.timelineHours, until: windowEnd)
            self.timeline = timeline
            self.timelineWindowEnd = windowEnd
            timelineAvailability = .available
        } catch {
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
        withAnimation(replacementAnimation) {
            historyOrigin = .loading
            historyApps = []
            historyError = nil
            historyCoverageDayCount = nil
        }
        let result = await selector.topApps(range: range)
        guard !Task.isCancelled, range == self.range else { return }
        withAnimation(replacementAnimation) {
            historyApps = result.apps.sorted { $0.energyWh > $1.energyWh }
            historyOrigin = result.origin
            historyCoverageDayCount = result.coverageDayCount
            historyError = result.errorDescription
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
        loadTask?.cancel()
        loadTask = Task { await loadApps() }
    }
}

/// One row in the full app-energy table: icon, name, Wh, CPU hours, and a
/// share-of-total bar. Tapping opens the per-app detail window; a chevron
/// appears on hover to hint at the interaction.
private struct StatsAppRow: View {
    let app: AppEnergy
    let share: Double
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                StatsAppIconView(bundleId: app.bundleId, displayName: app.displayName)
                    .frame(width: 20, height: 20)

                Text(app.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, share))))
                    }
                }
                .frame(width: 60, height: 5)

                Text(String(format: "%.1f Wh", app.energyWh))
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)

                Text(String(format: "%.1f h CPU", app.cpuHours))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(String(
            format: "%.1f watt-hours, %.1f CPU-hours", app.energyWh, app.cpuHours))
        .accessibilityHint("Opens energy details")
    }
}

/// One active-power row in the hybrid Today table, mirroring ``StatsAppRow``
/// anatomy with an additional green watts column before the Wh column. Apps
/// with no today history yet show "-" for Wh and CPU. Clickable: bundle ids are
/// real, so the per-app detail window opens.
private struct StatsActiveAppRow: View {
    let app: HybridTodayList.ActiveApp
    let energyWh: Double?
    let cpuHours: Double?
    let share: Double
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // appKey is the bundle id when resolvable, so it doubles as the
                // icon lookup key with the display name as fallback.
                StatsAppIconView(bundleId: app.appKey, displayName: app.displayName)
                    .frame(width: 20, height: 20)

                Text(app.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, share))))
                    }
                }
                .frame(width: 60, height: 5)

                Text(liveWattsText(app.watts))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)

                Text(energyWh.map { String(format: "%.1f Wh", $0) } ?? "-")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)

                Text(cpuHours.map { String(format: "%.1f h CPU", $0) } ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
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
}

/// The app's real icon when the bundle id resolves, otherwise a lettered
/// placeholder. Mirrors the icon-loading approach in ``TopAppsView``.
private struct StatsAppIconView: View {
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
                        .font(.system(size: 11, weight: .semibold))
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
