import Foundation
import JuiceCore
import JuiceXPCShared

/// Owns the live per-app power model and the polling loop that feeds it.
///
/// The loop is strictly scoped to the view lifetime: ``start()`` launches a
/// structured task that samples every 2 s, ``stop()`` cancels it and clears the
/// model so a reopened popover starts fresh.
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

    /// Each energy source makes its own client (see ``PowerlogEnergySource``),
    /// so the live view does the same.
    private let client: HelperClient
    /// Threshold 0: the hybrid merger applies the display threshold itself,
    /// and needs sub-threshold apps in the reading so grace-period holdovers
    /// keep decaying honestly instead of freezing at their last visible value.
    private let model = LivePowerModel(idleThresholdWatts: 0)
    private let interval: Duration
    private var loop: Task<Void, Never>?

    init(client: HelperClient = HelperClient(), interval: Duration = .seconds(2)) {
        self.client = client
        self.interval = interval
    }

    /// Begins sampling. Idempotent: an already-running loop is left in place.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sampleOnce()
                if Task.isCancelled { break }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Cancels the loop and forgets all accumulated state.
    func stop() {
        loop?.cancel()
        loop = nil
        model.reset()
        reading = nil
        status = .warmingUp
    }

    private func sampleOnce() async {
        do {
            let snapshot = try await client.fetchLiveEnergySample()
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
