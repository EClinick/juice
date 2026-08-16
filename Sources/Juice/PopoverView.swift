import AppKit
import SwiftUI
import JuiceCore

struct PopoverView: View {
    static let dashboardViewportHeight: CGFloat = 600

    @ObservedObject var model: BatteryViewModel
    @ObservedObject private var updater = UpdateController.shared
    @ObservedObject private var helper = HelperRegistrationController.shared
    /// The app-scoped live-power source of truth, shared with the Stats window
    /// so the two views can never disagree about which apps are live.
    @ObservedObject private var live = LivePowerCoordinator.shared
    @ObservedObject private var batterySession = BatterySessionCoordinator.shared

    /// Energy Mode reads cheaply from `pmset`, so a per-view controller is fine;
    /// it re-reads whenever the popover becomes active.
    @StateObject private var energyMode = EnergyModeController()

    private let selector = EnergySourceSelector()

    /// A per-instance live-loop identity. If SwiftUI spins up a second
    /// PopoverView while the first is still unwinding (rapid close/reopen), each
    /// instance owns a distinct token, so the stale instance's teardown detaches
    /// only itself and never the fresh, visible instance.
    @State private var consumerID = UUID()

    @State private var range: EnergyRange
    @AppStorage(StatsRangeVisibility.storageKey)
    private var rangeVisibilityStorage = StatsRangeVisibility.defaultStorageValue
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
    @State private var loadedHistoryRange: EnergyRange?
    @State private var loadTask: Task<Void, Never>?
    @State private var serverRefreshGeneration = 0
    /// MenuBarExtra may retain this hierarchy after its AppKit window closes.
    /// Drive work from the actual key-window lifecycle rather than relying on
    /// SwiftUI `onDisappear`, which is not guaranteed for retained content.
    @State private var surfaceIsActive = false

    private var replacementAnimation: Animation { juiceStandardEase }

    private var visibleRanges: [EnergyRange] {
        StatsRangeVisibility.visibleRanges(from: rangeVisibilityStorage)
    }

    private var showsLivePower: Bool {
        range.usesLivePower(onAC: model.reading?.onAC)
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
            if model.isMacMini {
                PopoverDashboardViewport(height: Self.dashboardViewportHeight) {
                    VStack(alignment: .leading, spacing: 10) {
                        MacMiniPowerView(
                            store: JuiceApp.sampler?.store,
                            refreshGeneration: serverRefreshGeneration)
                        updateControls
                    }
                }
            } else if let r = model.reading, r.hasBattery {
                PopoverDashboardViewport(height: Self.dashboardViewportHeight) {
                    VStack(alignment: .leading, spacing: 10) {
                        batteryDashboard(r)
                        updateControls
                    }
                }
            } else if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
                updateControls
            } else {
                Text("No battery detected.")
                    .foregroundStyle(.secondary)
                updateControls
            }

            Divider()

            HStack(spacing: 6) {
                Button("Refresh") {
                    model.refresh()
                    helper.refresh()
                    if model.isMacMini {
                        serverRefreshGeneration += 1
                    } else {
                        loadTask?.cancel()
                        loadTask = Task { await loadEnergy() }
                        Task { await energyMode.refresh() }
                    }
                }
                Button("Stats", action: showStatsWindow)
                Button("Settings", action: showSettingsWindow)
                Spacer()
                Button("Quit Juice") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: model.isMacMini ? 360 : 320)
        .environment(\.juiceSurfaceIsActive, surfaceIsActive)
        .background {
            WindowActivityReader { active in
                guard surfaceIsActive != active else { return }
                surfaceIsActive = active
                if active {
                    model.refresh()
                    helper.refresh()
                    applyInitialRange()
                    if !model.isMacMini {
                        Task { await energyMode.refresh() }
                    }
                } else {
                    loadTask?.cancel()
                }
                syncDataAttachments()
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            syncDataAttachments()
        }
        .task(id: surfaceIsActive) {
            if surfaceIsActive && !model.isMacMini {
                await loadEnergy()
            }
        }
        .onChange(of: range) {
            loadTask?.cancel()
            syncDataAttachments()
            guard surfaceIsActive else { return }
            loadTask = Task { await loadTopApps() }
        }
        .onChange(of: model.reading?.onAC) {
            syncDataAttachments()
            // The two sources carry independent modes, so the displayed one
            // changes the moment the machine is plugged in or unplugged.
            guard !model.isMacMini else { return }
            Task { await energyMode.refresh() }
        }
        // Energy Mode can also change from System Settings or a system prompt.
        // BatteryViewModel already observes the power-state notification, so its
        // published flag is the cheapest signal that a re-read is due.
        .onChange(of: model.isLowPowerModeEnabled) {
            guard !model.isMacMini else { return }
            Task { await energyMode.refresh() }
        }
        // That flag is false for both Automatic and High Power, so an external
        // switch between the two raises no notification at all. Ride the battery
        // refresh cadence instead: ~60 s while the popover is open, and only
        // while it is, which is cheap enough for an unprivileged pmset read.
        .onChange(of: model.readingGeneration) {
            guard surfaceIsActive, !model.isMacMini else { return }
            Task { await energyMode.refresh() }
        }
        .onChange(of: rangeVisibilityStorage) {
            range = StatsRangeVisibility.preferredRange(
                range,
                from: rangeVisibilityStorage)
        }
        .onChange(of: helper.readyGeneration) {
            // A newly registered helper may be the build that supports Energy
            // Mode writes, so the "restart to update" notice must not stick.
            energyMode.helperMayHaveUpdated()
            if surfaceIsActive && origin == .unavailable {
                retryTopApps()
            }
        }
        // Keep the normal SwiftUI teardown path as a fallback. The AppKit
        // activity reader above handles retained MenuBarExtra hierarchies.
        .onDisappear {
            surfaceIsActive = false
            loadTask?.cancel()
            live.setAttached(false, for: .popover(consumerID))
            batterySession.setAttached(false, for: .popover(consumerID))
        }
    }

    @ViewBuilder
    private var updateControls: some View {
        if updater.isAvailable {
            Divider()

            VStack(alignment: .leading, spacing: 5) {
                if let readyUpdate = updater.readyUpdate {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Juice \(readyUpdate.version) is ready")
                                .font(.caption.weight(.semibold))
                            Text("Restart Juice to finish installing.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update & Relaunch") {
                            updater.installReadyUpdate()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack(spacing: 0) {
                    Toggle("Automatic updates", isOn: Binding(
                        get: { updater.automaticallyUpdates },
                        set: { updater.automaticallyUpdates = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Automatic updates")
                    .accessibilityHint(
                        "Checks for and downloads updates automatically when enabled.")
                    if updater.readyUpdate == nil {
                        Spacer(minLength: 6)
                        Button("Check for Updates…") {
                            updater.checkForUpdates()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func batteryDashboard(_ reading: BatteryReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Gauge, its docked mode control, and the mode caption read as one
            // block, so they stay closer to each other than to the sections
            // below. No divider: the grouping is carried by spacing.
            VStack(alignment: .leading, spacing: 6) {
                BatteryHeroRow(
                    reading: reading,
                    timeRemainingText: model.timeRemainingText,
                    controller: energyMode,
                    isLowPowerModeEnabled: model.isLowPowerModeEnabled)
                    // The open fan hangs below the gauge over the caption
                    // line, so the hero must paint above its later siblings.
                    .zIndex(1)

                EnergyModeCaptions(controller: energyMode, onAC: reading.onAC)
            }
            .padding(.bottom, 2)
            .zIndex(1)

            // The hybrid's own section captions replace this header line;
            // rendering both would waste a row of the popover's height.
            if !showsLiveAppSections {
                HStack {
                    Text("Top energy users")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsLivePower,
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
                ranges: visibleRanges,
                hybrid: showsLivePower ? live.hybrid : nil,
                batteryWatts: model.reading.map { abs($0.watts) },
                systemLoadWatts: live.systemLoadWatts,
                onAC: model.reading?.onAC ?? false,
                totalAppWatts: showsLivePower ? live.reading?.totalAppWatts : nil,
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
                    windowEnd: timelineWindowEnd)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Keep `MenuBarExtra` as the app's only SwiftUI scene, as required by its
    /// removal-to-quit lifecycle. An AppKit presenter gives the same SwiftUI
    /// settings view a regular retained window without adding another scene.
    private func showSettingsWindow() {
        SettingsWindowPresenter.shared.show()
    }

    private func showStatsWindow() {
        if model.isMacMini {
            StatsWindowPresenter.shared.showServer(store: JuiceApp.sampler?.store)
        } else {
            StatsWindowPresenter.shared.show(
                selector: selector,
                timelineSource: timelineSource,
                model: model
            )
        }
    }

    /// Attaches to the shared live loop for Today, and for Session only while
    /// unplugged. Idempotent: repeated calls with the same state are absorbed.
    private func syncDataAttachments() {
        live.setAttached(
            surfaceIsActive && (model.isMacMini || showsLivePower),
            includesTodayHistory: !model.isMacMini && range == .today,
            for: .popover(consumerID))
        batterySession.setAttached(
            surfaceIsActive && !model.isMacMini && range == .session,
            for: .popover(consumerID))
    }

    private func applyInitialRange() {
        guard !didApplyInitialRange else { return }
        didApplyInitialRange = true
        range = StatsRangeVisibility.preferredRange(
            .initialRange(onAC: model.reading?.onAC),
            from: rangeVisibilityStorage)
    }

    @ViewBuilder
    private var energyStatus: some View {
        if showsLivePower, live.status == .helperOutdated {
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
        showsLivePower && !(live.hybrid?.active.isEmpty ?? true)
    }

    private var timelineSource: EnergySource? {
        if let store = JuiceApp.sampler?.store {
            return StoreEnergySource(store: store)
        }
        return nil
    }

    private func loadEnergy() async {
        await loadTopApps()
        guard !Task.isCancelled else { return }
        // Charge history comes from the local sample store. One captured
        // window end anchors both the store query and the chart's x-domain.
        if let store = JuiceApp.sampler?.store {
            let windowEnd = Date()
            do {
                let loadedTimeline = try await StoreEnergySource(store: store)
                    .batteryTimeline(hours: 24, until: windowEnd)
                guard !Task.isCancelled else { return }
                self.timeline = loadedTimeline
                self.timelineWindowEnd = windowEnd
                timelineAvailability = .available
            } catch {
                guard !Task.isCancelled else { return }
                timelineAvailability = .unavailable
            }
            guard !Task.isCancelled else { return }
            let loadedInsights = await InsightsProvider(store: store).currentInsights()
            guard !Task.isCancelled else { return }
            insights = loadedInsights
        } else {
            guard !Task.isCancelled else { return }
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
        let result = await selector.topApps(range: range, limit: 8)
        guard !Task.isCancelled, range == self.range else { return }
        withAnimation(replacementAnimation) {
            historyApps = result.apps
            historyOrigin = result.origin
            historyCoverageDayCount = result.coverageDayCount
            historyError = result.errorDescription
            loadedHistoryRange = range
        }
    }

    private func retryTopApps() {
        guard surfaceIsActive else { return }
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

/// Gives MenuBarExtra dashboards a finite viewport while leaving action
/// controls outside the scrollable region. ScrollView has no useful intrinsic
/// height in a menu-bar panel, so measure its content and cap the viewport to
/// prevent clipping without leaving empty space above the action footer.
struct PopoverDashboardViewport<Content: View>: View {
    let height: CGFloat
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat?
    @State private var showsScrollHint = true
    @State private var scrollHintHovered = false

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            PopoverScrollStateObserver { canScrollDown in
                                showsScrollHint = canScrollDown
                            }
                        }

                    Color.clear
                        .frame(height: 1)
                        .id(PopoverDashboardScrollTarget.bottom)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: PopoverDashboardContentHeightKey.self,
                            value: geometry.size.height)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(contentHeight ?? height, height))
            .onPreferenceChange(PopoverDashboardContentHeightKey.self) { measuredHeight in
                guard measuredHeight > 0 else { return }
                contentHeight = measuredHeight
            }
            .overlay(alignment: .bottom) {
                if showsScrollHint {
                    ZStack(alignment: .bottom) {
                        Color.clear
                            .allowsHitTesting(false)

                        Button {
                            scrollToBottom(using: proxy)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Scroll")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(PopoverScrollHintButtonStyle(
                            hovered: scrollHintHovered))
                        .onHover { scrollHintHovered = $0 }
                        .help("Scroll to bottom")
                        .accessibilityLabel("Scroll to bottom")
                        .accessibilityIdentifier("popover-scroll-to-bottom")
                        .padding(.bottom, 6)
                    }
                    .frame(height: 48)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        let scroll = {
            proxy.scrollTo(PopoverDashboardScrollTarget.bottom, anchor: .bottom)
        }
        if reduceMotion {
            scroll()
        } else {
            withAnimation(.easeOut(duration: 0.22), scroll)
        }
    }
}

private struct PopoverDashboardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum PopoverDashboardScrollTarget: Hashable {
    case bottom
}

private struct PopoverScrollHintButtonStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovered ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial),
                in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.primary.opacity(hovered ? 0.2 : 0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed)
    }
}

enum PopoverScrollHintVisibility {
    private static let bottomTolerance: CGFloat = 8

    static func shouldShow(
        documentBounds: CGRect,
        visibleRect: CGRect,
        isFlipped: Bool
    ) -> Bool {
        guard documentBounds.height > visibleRect.height + bottomTolerance else {
            return false
        }

        let remaining = if isFlipped {
            documentBounds.maxY - visibleRect.maxY
        } else {
            visibleRect.minY - documentBounds.minY
        }
        return remaining > bottomTolerance
    }
}

private struct PopoverScrollStateObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> PopoverScrollStateObserverView {
        let view = PopoverScrollStateObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(
        _ nsView: PopoverScrollStateObserverView,
        context: Context
    ) {
        nsView.onChange = onChange
        nsView.scheduleAttachment()
    }
}

private final class PopoverScrollStateObserverView: NSView {
    var onChange: ((Bool) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private var observations: [NSObjectProtocol] = []
    private var lastValue: Bool?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleAttachment()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAttachment()
    }

    deinit {
        removeObservations()
    }

    func scheduleAttachment() {
        DispatchQueue.main.async { [weak self] in
            self?.attachToEnclosingScrollView()
        }
    }

    private func attachToEnclosingScrollView() {
        guard let scrollView = enclosingScrollView else { return }

        if observedScrollView !== scrollView {
            removeObservations()
            observedScrollView = scrollView
            observe(scrollView)
        }

        refresh()
    }

    private func observe(_ scrollView: NSScrollView) {
        let center = NotificationCenter.default
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        observations.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })

        if let documentView = scrollView.documentView {
            documentView.postsFrameChangedNotifications = true
            observations.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    private func refresh() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView
        else { return }

        scrollView.layoutSubtreeIfNeeded()
        let visibleRect = documentView.convert(
            scrollView.contentView.bounds,
            from: scrollView.contentView)
        let value = PopoverScrollHintVisibility.shouldShow(
            documentBounds: documentView.bounds,
            visibleRect: visibleRect,
            isFlipped: documentView.isFlipped)

        guard value != lastValue else { return }
        lastValue = value
        onChange?(value)
    }

    private func removeObservations() {
        let center = NotificationCenter.default
        observations.forEach(center.removeObserver)
        observations.removeAll()
    }
}
