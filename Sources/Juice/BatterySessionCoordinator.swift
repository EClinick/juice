import Foundation
import Combine
import JuiceCore

/// One shared, render-ready battery-session result for the popover and Stats.
enum BatterySessionEnergyCoverage {
    case full
    case partial
    case unavailable
}

struct BatterySessionUsageResult {
    var session: BatterySession?
    var apps: [AppEnergy]
    var origin: DataOrigin
    var errorDescription: String?
    /// Whether retained PowerLog intervals cover all, part, or none of the
    /// resolved off-AC session.
    var energyCoverage: BatterySessionEnergyCoverage
}

/// Resolves battery samples into a session and loads per-app energy for that
/// exact start/end window. Dependencies are closures so the boundary and error
/// states can be tested without the helper or the app's real database.
struct BatterySessionUsageLoader {
    private static let historyLookback: TimeInterval = 90 * 24 * 3600

    let loadSamples: (Date, Date) async throws -> [StoredBatterySample]
    let currentReading: () -> BatteryReading?
    let loadApps: (EnergyWindow) async throws -> [AppEnergy]

    init(
        loadSamples: @escaping (Date, Date) async throws -> [StoredBatterySample],
        currentReading: @escaping () -> BatteryReading?,
        loadApps: @escaping (EnergyWindow) async throws -> [AppEnergy]
    ) {
        self.loadSamples = loadSamples
        self.currentReading = currentReading
        self.loadApps = loadApps
    }

    init?(store: JuiceStore?, source: PowerlogEnergySource = PowerlogEnergySource()) {
        guard let store else { return nil }
        self.init(
            loadSamples: { start, end in
                try await Task.detached {
                    try store.samples(since: start, until: end)
                }.value
            },
            currentReading: { try? BatteryMonitor.read() },
            loadApps: { try await source.topApps(in: $0) })
    }

    func load(now: Date = Date()) async -> BatterySessionUsageResult {
        let historyStart = now.addingTimeInterval(-Self.historyLookback)
        var samples: [StoredBatterySample]
        do {
            samples = try await loadSamples(historyStart, now)
        } catch {
            return BatterySessionUsageResult(
                session: nil, apps: [], origin: .unavailable,
                errorDescription: "Battery-session history could not be read: \(error.localizedDescription)",
                energyCoverage: .unavailable)
        }

        if let reading = currentReading() {
            samples.append(StoredBatterySample(
                date: now,
                percent: reading.percent,
                onAC: reading.onAC,
                isCharging: reading.isCharging,
                watts: reading.watts))
        }

        guard let session = BatterySessionResolver.latest(in: samples) else {
            return BatterySessionUsageResult(
                session: nil, apps: [], origin: .live,
                errorDescription: nil, energyCoverage: .unavailable)
        }

        let window = EnergyWindow(start: session.start, end: session.end)
        let retentionStart = PowerlogEnergySource.retainedHistoryStart(now: now)
        let energyCoverage: BatterySessionEnergyCoverage
        if session.end <= retentionStart {
            energyCoverage = .unavailable
        } else if session.start < retentionStart {
            energyCoverage = .partial
        } else {
            energyCoverage = .full
        }

        // Avoid a helper query that cannot return any fully-contained interval
        // for a session wholly older than PowerLog's retained window.
        guard energyCoverage != .unavailable else {
            return BatterySessionUsageResult(
                session: session, apps: [], origin: .live,
                errorDescription: nil, energyCoverage: .unavailable)
        }

        do {
            return BatterySessionUsageResult(
                session: session,
                apps: try await loadApps(window),
                origin: .live,
                errorDescription: nil,
                energyCoverage: energyCoverage)
        } catch {
            await MainActor.run {
                HelperRegistrationController.shared.refresh()
            }
            return BatterySessionUsageResult(
                session: session, apps: [], origin: .unavailable,
                errorDescription: error.localizedDescription,
                energyCoverage: energyCoverage)
        }
    }
}

/// App-scoped source of truth for the current/last battery session.
///
/// Work runs only while the popover or Stats is displaying Session. Generation
/// tokens prevent a stale refresh from publishing after a reconnect, range
/// change, or newer manual retry.
@MainActor
final class BatterySessionCoordinator: ObservableObject {
    static let shared = BatterySessionCoordinator()

    enum ConsumerKind: Hashable { case popover, stats }

    struct Consumer: Hashable {
        let kind: ConsumerKind
        let id: UUID

        static func popover(_ id: UUID) -> Consumer { Consumer(kind: .popover, id: id) }
        static func stats(_ id: UUID) -> Consumer { Consumer(kind: .stats, id: id) }
    }

    @Published private(set) var result: BatterySessionUsageResult?

    private let load: () async -> BatterySessionUsageResult
    private let refreshInterval: Duration
    private var attached: Set<Consumer> = []
    private var refreshTask: Task<Void, Never>?
    private var manualRefresh: Task<Void, Never>?
    private var generation = 0

    init(
        load: @escaping () async -> BatterySessionUsageResult = {
            guard let loader = BatterySessionUsageLoader(store: JuiceApp.sampler?.store) else {
                return BatterySessionUsageResult(
                    session: nil, apps: [], origin: .unavailable,
                    errorDescription: "Battery-session history is unavailable because the local store could not be opened.",
                    energyCoverage: .unavailable)
            }
            return await loader.load()
        },
        refreshInterval: Duration = .seconds(30)
    ) {
        self.load = load
        self.refreshInterval = refreshInterval
    }

    func setAttached(_ wantsSession: Bool, for consumer: Consumer) {
        let wasEmpty = attached.isEmpty
        if wantsSession { attached.insert(consumer) } else { attached.remove(consumer) }
        if wasEmpty && !attached.isEmpty {
            startRefreshing()
        } else if !wasEmpty && attached.isEmpty {
            stopRefreshing()
        }
    }

    func detachAll(kind: ConsumerKind) {
        let wasEmpty = attached.isEmpty
        attached = attached.filter { $0.kind != kind }
        if !wasEmpty && attached.isEmpty { stopRefreshing() }
    }

    func refreshNow() {
        guard !attached.isEmpty else { return }
        manualRefresh?.cancel()
        let token = invalidateRefreshes()
        manualRefresh = Task { [weak self] in
            await self?.performRefresh(generation: token)
        }
    }

    var attachedConsumerCount: Int { attached.count }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performRefresh(generation: self.invalidateRefreshes())
                if Task.isCancelled { break }
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        manualRefresh?.cancel()
        manualRefresh = nil
        _ = invalidateRefreshes()
    }

    private func invalidateRefreshes() -> Int {
        generation += 1
        return generation
    }

    private func performRefresh(generation: Int) async {
        let result = await load()
        guard !Task.isCancelled, generation == self.generation else { return }
        self.result = result
    }
}
