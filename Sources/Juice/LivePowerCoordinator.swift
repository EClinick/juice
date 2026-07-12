import Foundation
import JuiceCore

/// The sampling half of the coordinator: something that can be started and
/// stopped and publishes a live reading plus a status. ``LivePowerController``
/// is the production conformer; tests substitute a deterministic double so the
/// coordinator's merge and reference-counting logic can be exercised without a
/// real XPC polling loop.
@MainActor
protocol LivePowerSource: AnyObject {
    var reading: LivePowerReading? { get }
    var status: LivePowerController.Status { get }
    var readingUpdates: AsyncStream<LivePowerReading?> { get }
    var statusUpdates: AsyncStream<LivePowerController.Status> { get }
    func start()
    func stop()
}

extension LivePowerController: LivePowerSource {
    var readingUpdates: AsyncStream<LivePowerReading?> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await value in $reading.values { continuation.yield(value) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var statusUpdates: AsyncStream<LivePowerController.Status> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await value in $status.values { continuation.yield(value) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// App-scoped single source of truth for the live "drawing power now" view.
///
/// The popover and the Stats window both render this coordinator's published
/// state, so they can never disagree about which apps are live: there is one
/// polling loop, one ``LivePowerModel`` (EMA state), one ``LiveTodayMerger``
/// (30 s grace / active-membership state), one Today history fetch, and one
/// merged ``HybridTodayList``.
///
/// Attachment is reference counted per consumer via an idempotent token API.
/// A consumer calls ``setAttached(_:for:)`` with a stable id whenever its
/// (visible AND on the Today range) condition changes; the coordinator samples
/// while at least one consumer is attached and pauses when the last detaches.
/// Double calls from SwiftUI lifecycle quirks are absorbed because attachment
/// is keyed by consumer id, not a raw counter.
///
/// Pausing does NOT reset the merger's grace state - detaching only stops the
/// clock, so a brief close/reopen keeps an app in the active section instead of
/// wiping the timeline the way a per-view controller used to. On the next
/// attach the grace state is re-aged immediately against the current clock so a
/// stale active row cannot linger past its window.
@MainActor
final class LivePowerCoordinator: ObservableObject {
    /// The one instance the whole app shares.
    static let shared = LivePowerCoordinator()

    /// The kind of view a consumer belongs to, so the presenter can detach a
    /// whole family (e.g. every Stats window instance) without knowing each
    /// instance's random id.
    enum ConsumerKind: Hashable {
        case popover
        case stats
    }

    /// A per-instance identity for a consumer of the live loop. Each view
    /// instance mints its own `id`, so a stale instance's teardown can only
    /// remove ITS OWN token - it can never detach a fresh instance that shares
    /// the same ``ConsumerKind`` during a rapid close/reopen. Attachment is
    /// idempotent per id.
    struct Consumer: Hashable {
        let kind: ConsumerKind
        let id: UUID

        init(kind: ConsumerKind, id: UUID = UUID()) {
            self.kind = kind
            self.id = id
        }

        static func popover(_ id: UUID) -> Consumer { Consumer(kind: .popover, id: id) }
        static func stats(_ id: UUID) -> Consumer { Consumer(kind: .stats, id: id) }
    }

    /// The latest per-tick live reading (nil until two snapshots establish a
    /// delta, or while stopped). Drives the attribution footers.
    @Published private(set) var reading: LivePowerReading?
    /// The controller's sampling status, driving the "Live" hints and the
    /// outdated-helper notice.
    @Published private(set) var status: LivePowerController.Status = .warmingUp
    /// The merged live/history split both views render verbatim.
    @Published private(set) var hybrid: HybridTodayList?
    /// The full Today history query result both views render verbatim: apps,
    /// origin, coverage, and any query error. Published so a failed or empty
    /// coordinator fetch is reflected honestly instead of silently dropping the
    /// Earlier Today rows.
    @Published private(set) var todayResult: EnergySourceSelector.TopAppsResult?

    private let source: LivePowerSource
    private let loadToday: () async -> EnergySourceSelector.TopAppsResult
    private let now: () -> Date
    private let todayRefreshInterval: Duration
    private var merger = LiveTodayMerger()

    /// The set of currently-attached consumers. Sampling runs while non-empty.
    private var attached: Set<Consumer> = []
    private var readingObservation: Task<Void, Never>?
    private var statusObservation: Task<Void, Never>?
    private var todayRefresh: Task<Void, Never>?
    /// The manual (retry) refresh task, tracked so it is cancelled and replaced
    /// on each retry and cancelled by ``stopSampling()``.
    private var manualRefresh: Task<Void, Never>?
    /// Monotonic token bumped whenever refreshes are invalidated (a new manual
    /// retry starts, or sampling stops). A refresh that finishes carrying a
    /// stale token is discarded, so an older completion can never overwrite a
    /// newer result and a completion after detach never publishes.
    private var todayRefreshGeneration = 0

    init(
        source: LivePowerSource? = nil,
        loadToday: @escaping () async -> EnergySourceSelector.TopAppsResult = {
            // The full, energy-sorted list serves both consumers: the popover
            // caps it at render time and the Stats window shows it whole.
            var result = await EnergySourceSelector().topApps(range: .today, limit: nil)
            result.apps.sort { $0.energyWh > $1.energyWh }
            return result
        },
        now: @escaping () -> Date = { Date() },
        todayRefreshInterval: Duration = .seconds(30)
    ) {
        self.source = source ?? LivePowerController()
        self.loadToday = loadToday
        self.now = now
        self.todayRefreshInterval = todayRefreshInterval
    }

    /// Idempotently attaches or detaches a consumer. Callers pass whether the
    /// consumer currently wants live data (visible AND on the Today range); the
    /// coordinator reconciles the running state from the resulting attached set.
    func setAttached(_ wantsLive: Bool, for consumer: Consumer) {
        let wasEmpty = attached.isEmpty
        if wantsLive {
            attached.insert(consumer)
        } else {
            attached.remove(consumer)
        }
        let isEmpty = attached.isEmpty

        if wasEmpty && !isEmpty {
            startSampling()
        } else if !wasEmpty && isEmpty {
            stopSampling()
        }
    }

    /// Detaches every consumer of a given kind, regardless of instance id. The
    /// Stats window presenter calls this from `windowWillClose` because a
    /// retained window's SwiftUI `.onDisappear` is unreliable: this guarantees
    /// the window's token(s) are released even if the view never sees teardown.
    func detachAll(kind: ConsumerKind) {
        let wasEmpty = attached.isEmpty
        attached = attached.filter { $0.kind != kind }
        if !wasEmpty && attached.isEmpty {
            stopSampling()
        }
    }

    /// The count of attached consumers, for tests asserting reference behavior.
    var attachedConsumerCount: Int { attached.count }

    /// Forces an immediate off-cadence Today refresh (a manual retry after a
    /// failed or empty fetch). No-op when nothing is attached, since the
    /// published result is only shown while a consumer is on Today.
    ///
    /// The retry is tracked and invalidates prior refreshes: a bumped
    /// generation means any in-flight periodic or earlier manual fetch is
    /// discarded on completion, so a newer result can never be clobbered by an
    /// older one and a completion after detach never publishes.
    func refreshTodayNow() {
        guard !attached.isEmpty else { return }
        manualRefresh?.cancel()
        let generation = invalidateRefreshes()
        manualRefresh = Task { [weak self] in
            await self?.performRefresh(generation: generation)
        }
    }

    private func startSampling() {
        // Re-age grace immediately so a cached active row from a previous
        // session cannot linger past its window before the first fresh tick.
        reading = nil
        recomputeHybrid()

        source.start()
        observeSource()
        startTodayRefresh()
    }

    private func stopSampling() {
        source.stop()
        readingObservation?.cancel()
        readingObservation = nil
        statusObservation?.cancel()
        statusObservation = nil
        todayRefresh?.cancel()
        todayRefresh = nil
        manualRefresh?.cancel()
        manualRefresh = nil
        // Bump the generation so any fetch still in flight (periodic or manual)
        // is discarded on completion instead of publishing after detach.
        _ = invalidateRefreshes()
        // The source's stop() clears its reading; mirror that so the hints fall
        // back to "warming up" on reattach. The merger is deliberately NOT
        // reset: grace state persists across close/reopen.
        reading = nil
        status = source.status
    }

    /// Mirrors the source's published state onto the coordinator and recomputes
    /// the merged list whenever a new reading lands. Status is observed
    /// separately because it can change (helper outdated / a failed fetch) on a
    /// tick that leaves the reading untouched.
    private func observeSource() {
        readingObservation?.cancel()
        readingObservation = Task { [weak self] in
            guard let self else { return }
            for await reading in self.source.readingUpdates {
                if Task.isCancelled { break }
                self.apply(reading: reading)
            }
        }
        statusObservation?.cancel()
        statusObservation = Task { [weak self] in
            guard let self else { return }
            for await status in self.source.statusUpdates {
                if Task.isCancelled { break }
                self.status = status
            }
        }
    }

    /// Refreshes today's history immediately on attach, then on a slow cadence
    /// while sampling is active, so the "earlier today" section and the per-app
    /// Wh borrow stay current without a query every 2 s live tick.
    private func startTodayRefresh() {
        todayRefresh?.cancel()
        todayRefresh = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Each iteration mints its own generation so a slower fetch
                // started earlier (periodic or manual) can never publish over
                // this one: only the latest-started request survives the
                // equality check in performRefresh.
                await self.performRefresh(generation: self.invalidateRefreshes())
                if Task.isCancelled { break }
                try? await Task.sleep(for: self.todayRefreshInterval)
            }
        }
    }

    /// Bumps and returns the new refresh generation, invalidating any fetch that
    /// captured the prior value.
    private func invalidateRefreshes() -> Int {
        todayRefreshGeneration += 1
        return todayRefreshGeneration
    }

    /// Runs one Today fetch and publishes it only if `generation` is still the
    /// current one when the fetch returns - so a stale (older or detached-past)
    /// completion is dropped rather than overwriting a newer result.
    private func performRefresh(generation: Int) async {
        let result = await loadToday()
        guard !Task.isCancelled, generation == todayRefreshGeneration else { return }
        todayResult = result
        recomputeHybrid()
    }

    /// Stores the latest reading and re-folds it into the hybrid. Synchronous so
    /// the stream observer and the tests share one deterministic path.
    func apply(reading: LivePowerReading?) {
        self.reading = reading
        recomputeHybrid()
    }

    /// Replaces today's result and re-folds. Used by tests to inject a
    /// deterministic history without a store query.
    func setToday(_ result: EnergySourceSelector.TopAppsResult) {
        todayResult = result
        recomputeHybrid()
    }

    /// Folds the latest live reading into today's history. The merger needs the
    /// wall clock for its grace period, so the clock is captured here rather
    /// than inside the merger. This is the single place the merger ever runs.
    private func recomputeHybrid() {
        hybrid = merger.merge(live: reading, today: todayResult?.apps ?? [], now: now())
    }
}
