import Foundation
import JuiceCore
import JuiceXPCShared

/// Owns the live per-app power model and the polling loop that feeds it.
///
/// The loop is strictly scoped to the view lifetime: ``start()`` launches a
/// structured task, ``stop()`` cancels it and clears the model so a reopened
/// popover starts fresh. The cadence can change while running without replacing
/// the loop or resetting the model's cumulative-counter baseline.
@MainActor
final class LivePowerController: ObservableObject {
    /// The current live view state, driving what the UI renders.
    enum Status: Equatable {
        /// At least two snapshots ingested; ``reading`` is populated.
        case sampling
        /// Only the first snapshot seen so far; no delta yet.
        case warmingUp
        /// The installed helper predates the live-power capability.
        case helperOutdated
        /// A fetch failed for another reason; carries the message.
        case unavailable(String)
    }

    @Published private(set) var reading: LivePowerReading?
    @Published private(set) var status: Status = .warmingUp

    /// Fetch closure kept injectable so cadence changes can be tested without a
    /// real helper connection. Production captures its own ``HelperClient``.
    private let fetchSnapshot: () async throws -> LiveEnergySnapshot
    /// Delay seam used to exercise cancellation ownership deterministically.
    private let sleep: (Duration) async -> Void
    /// Threshold 0: the hybrid merger applies the display threshold itself,
    /// and needs sub-threshold apps in the reading so grace-period holdovers
    /// keep decaying honestly instead of freezing at their last visible value.
    private let model = LivePowerModel(idleThresholdWatts: 0)
    private let responsiveInterval: Duration
    private let backgroundInterval: Duration
    private(set) var samplingCadence: LivePowerSamplingCadence = .responsive
    private var loop: Task<Void, Never>?
    /// The loop owns exactly one cancellable delay between samples. A cadence
    /// change cancels only this delay, causing it to be replaced with the new
    /// interval; it never creates a second sampling loop.
    private var sampleDelay: Task<Void, Never>?
    /// Identifies the current delay owner. A cancelled loop can resume after a
    /// rapid stop/start, but its cleanup must not clear the replacement loop's
    /// delay handle or later cadence changes could no longer wake it promptly.
    private var sampleDelayGeneration = 0
    private var cadenceGeneration = 0

    init(
        client: HelperClient = HelperClient(),
        interval: Duration = .seconds(2),
        backgroundInterval: Duration = .seconds(5)
    ) {
        fetchSnapshot = { try await client.fetchLiveEnergySample() }
        sleep = { duration in _ = try? await Task.sleep(for: duration) }
        responsiveInterval = interval
        self.backgroundInterval = backgroundInterval
    }

    /// Test seam for deterministic snapshots and short scheduling intervals.
    init(
        fetchSnapshot: @escaping () async throws -> LiveEnergySnapshot,
        interval: Duration = .seconds(2),
        backgroundInterval: Duration = .seconds(5),
        sleep: @escaping (Duration) async -> Void = { duration in
            _ = try? await Task.sleep(for: duration)
        }
    ) {
        self.fetchSnapshot = fetchSnapshot
        self.sleep = sleep
        responsiveInterval = interval
        self.backgroundInterval = backgroundInterval
    }

    /// Begins sampling. Idempotent: an already-running loop is left in place.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sampleOnce()
                if Task.isCancelled { break }
                guard await self.waitForNextSample() else { break }
            }
        }
    }

    /// Changes the delay used by the existing loop without stopping it. If the
    /// loop is currently sleeping, replace that delay promptly; if it is
    /// fetching, the next delay naturally observes the new cadence.
    func setSamplingCadence(_ cadence: LivePowerSamplingCadence) {
        guard samplingCadence != cadence else { return }
        samplingCadence = cadence
        cadenceGeneration &+= 1
        sampleDelay?.cancel()
    }

    /// Cancels the loop and forgets all accumulated state.
    func stop() {
        loop?.cancel()
        loop = nil
        sampleDelayGeneration &+= 1
        sampleDelay?.cancel()
        sampleDelay = nil
        model.reset()
        reading = nil
        status = .warmingUp
    }

    /// Waits for one complete interval at the current cadence. A cadence change
    /// cancels the current delay and starts a fresh delay at the new interval;
    /// the caller samples only after that replacement delay finishes.
    private func waitForNextSample() async -> Bool {
        while !Task.isCancelled {
            let generation = cadenceGeneration
            let interval = switch samplingCadence {
            case .responsive: responsiveInterval
            case .background: backgroundInterval
            }
            sampleDelayGeneration &+= 1
            let delayGeneration = sampleDelayGeneration
            let delay = Task { await sleep(interval) }
            sampleDelay = delay
            await delay.value
            if delayGeneration == sampleDelayGeneration {
                sampleDelay = nil
            }

            guard !Task.isCancelled else { return false }
            if generation == cadenceGeneration { return true }
        }
        return false
    }

    func sampleOnce() async {
        do {
            let snapshot = try await fetchSnapshot()
            guard !Task.isCancelled else { return }
            if let newReading = model.ingest(snapshot) {
                reading = newReading
                status = .sampling
            } else if reading == nil {
                // First snapshot only establishes a baseline.
                status = .warmingUp
            }
        } catch HelperClientError.helperOutdated {
            // A cancelled loop must not overwrite the state stop() just reset.
            guard !Task.isCancelled else { return }
            status = .helperOutdated
        } catch {
            guard !Task.isCancelled else { return }
            status = .unavailable(error.localizedDescription)
        }
    }
}
