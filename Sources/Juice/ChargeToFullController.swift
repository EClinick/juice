import Foundation
import JuiceSmartChargingBridge

/// The actionable reason reported by macOS. A generic "plugged in, not
/// charging" reading is deliberately not representable here.
struct SystemChargeHold: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case optimized
        case limit
    }

    let kind: Kind
    let chargeLimit: Int
}

enum ChargeToFullReason: Equatable, Sendable {
    case optimized(currentPercent: Int)
    case limit(percent: Int)

    var headline: String {
        switch self {
        case .optimized: return "Charging On Hold"
        case .limit(let percent): return "Charged to \(percent)% Limit"
        }
    }

    var rowTitle: String {
        switch self {
        case .optimized(let percent): return "Held at \(percent)%"
        case .limit(let percent): return "Charged to your \(percent)% limit"
        }
    }

    var rowDetail: String {
        switch self {
        case .optimized:
            return "Optimized charging is protecting battery health."
        case .limit:
            return "Charge to 100% for this session."
        }
    }
}

enum ChargeToFullState: Equatable, Sendable {
    case ready(ChargeToFullReason)
    case starting(ChargeToFullReason)
    case accepted(ChargeToFullReason)
    case failed(ChargeToFullReason)

    var reason: ChargeToFullReason {
        switch self {
        case .ready(let reason),
             .starting(let reason),
             .accepted(let reason),
             .failed(let reason):
            return reason
        }
    }

    var headline: String {
        switch self {
        case .starting, .accepted: return "Starting Full Charge"
        case .ready, .failed: return reason.headline
        }
    }
}

/// Owns the contextual Charge to Full row. Both operations use the private
/// PowerUI client that Control Center uses, but are injected so the state
/// machine is tested without touching the machine's real charging state.
@MainActor
final class ChargeToFullController: ObservableObject {
    @Published private(set) var state: ChargeToFullState?
    @Published private(set) var isRequesting = false

    private let readStatus: @Sendable () async throws -> SystemChargeHold?
    private let requestFullCharge: @Sendable () async throws -> Void
    private let now: () -> Date
    private var generation = 0
    private var acceptedAt: Date?
    private var lastReading: BatteryReading?
    private var confirmationTask: Task<Void, Never>?

    static let confirmationGrace: TimeInterval = 10

    init(
        readStatus: (@Sendable () async throws -> SystemChargeHold?)? = nil,
        requestFullCharge: (@Sendable () async throws -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.readStatus = readStatus ?? { try await Self.readSystemStatus() }
        self.requestFullCharge = requestFullCharge ?? {
            try await Self.requestSystemFullCharge()
        }
        self.now = now
    }

    /// Reconciles the private smart-charging state with a fresh battery read.
    /// Battery context can hide an action, but can never create one.
    func refresh(reading: BatteryReading?) async {
        lastReading = reading
        if isRequesting {
            // An in-flight system request cannot make an unplugged or already
            // charging battery actionable again. Hide the contextual row as
            // soon as the fresh battery reading invalidates it, while letting
            // the request finish and reconcile normally.
            if !Self.couldBeActionable(reading) {
                clearState()
            }
            return
        }
        generation += 1
        let refreshGeneration = generation

        guard Self.couldBeActionable(reading) else {
            clearState()
            return
        }

        let result: Result<SystemChargeHold?, any Error>
        do {
            result = .success(try await readStatus())
        } catch {
            result = .failure(error)
        }
        guard generation == refreshGeneration, !isRequesting else { return }

        apply(result, reading: reading)
    }

    private func apply(
        _ result: Result<SystemChargeHold?, any Error>,
        reading: BatteryReading?
    ) {
        // The PowerUI state and IOKit current do not update atomically. Keep a
        // successful request stable briefly, even if an immediate re-read still
        // sees the old hold, but never claim that charging itself has begun.
        if case .accepted = state, transitionIsFresh { return }

        clearAcceptedTransition()
        switch result {
        case .success(let hold?):
            state = Self.reason(for: hold, reading: reading).map(ChargeToFullState.ready)
        case .success(nil):
            state = nil
        case .failure:
            // Initial detection is intentionally quiet. If the private API is
            // absent or changes, Juice simply does not offer the command.
            state = nil
        }
    }

    /// Requests a one-time override. Returns true only when macOS accepted it,
    /// so the caller can trigger an immediate battery refresh.
    @discardableResult
    func chargeToFull() async -> Bool {
        guard !isRequesting, let current = state else { return false }
        let reason = current.reason
        switch current {
        case .ready, .failed:
            break
        case .starting, .accepted:
            return false
        }

        generation += 1
        isRequesting = true
        state = .starting(reason)
        var requestWasInvoked = false

        do {
            try Task.checkCancellation()
            requestWasInvoked = true
            try await requestFullCharge()
            generation += 1
            isRequesting = false
            if Self.couldBeActionable(lastReading) {
                acceptedAt = now()
                state = .accepted(reason)
                scheduleConfirmationRefresh()
            } else {
                clearState()
            }
            return true
        } catch is CancellationError {
            generation += 1
            isRequesting = false
            clearAcceptedTransition()
            if requestWasInvoked {
                // Cancellation cannot undo a private XPC call that may already
                // have crossed the process boundary. Re-read in a detached task
                // instead of pretending the request definitely did not happen.
                await reconcileAfterUncertainRequest(reading: lastReading)
            } else {
                state = .ready(reason)
            }
            return false
        } catch {
            generation += 1
            isRequesting = false
            clearAcceptedTransition()
            // A battery refresh can arrive while the private request is in
            // flight. Do not restore a retry for a hold that became ineligible
            // in the meantime (for example, after unplugging).
            if Self.couldBeActionable(lastReading) {
                state = .failed(reason)
            } else {
                clearState()
            }
            return false
        }
    }

    private func reconcileAfterUncertainRequest(reading: BatteryReading?) async {
        generation += 1
        let refreshGeneration = generation
        guard Self.couldBeActionable(reading) else {
            clearState()
            return
        }

        let reader = readStatus
        let result = await Task.detached(priority: .userInitiated) {
            do {
                return Result<SystemChargeHold?, any Error>.success(
                    try await reader())
            } catch {
                return Result<SystemChargeHold?, any Error>.failure(error)
            }
        }.value
        guard generation == refreshGeneration, !isRequesting else { return }
        apply(result, reading: reading)
    }

    private func scheduleConfirmationRefresh() {
        confirmationTask?.cancel()
        let timestamp = acceptedAt
        confirmationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.confirmationGrace))
            } catch {
                return
            }
            guard let self,
                  self.acceptedAt == timestamp,
                  case .accepted = self.state else { return }
            await self.refresh(reading: self.lastReading)
        }
    }

    private func clearAcceptedTransition() {
        acceptedAt = nil
        confirmationTask?.cancel()
        confirmationTask = nil
    }

    private func clearState() {
        clearAcceptedTransition()
        state = nil
    }

    private var transitionIsFresh: Bool {
        guard let acceptedAt else { return false }
        return now().timeIntervalSince(acceptedAt) < Self.confirmationGrace
    }

    private static func couldBeActionable(_ reading: BatteryReading?) -> Bool {
        guard let reading else { return false }
        return reading.hasBattery
            && reading.onAC
            && !reading.isCharging
            && reading.percent < 100
    }

    private static func reason(
        for hold: SystemChargeHold,
        reading: BatteryReading?
    ) -> ChargeToFullReason? {
        switch hold.kind {
        case .optimized:
            return .optimized(currentPercent: reading?.percent ?? 80)
        case .limit:
            guard (1..<100).contains(hold.chargeLimit) else { return nil }
            return .limit(percent: hold.chargeLimit)
        }
    }

    // MARK: - Dynamic macOS bridge

    private nonisolated static func readSystemStatus() async throws -> SystemChargeHold? {
        try await Task.detached(priority: .userInitiated) {
            var kind = JSCChargeHoldKind(rawValue: 0)!
            var limit = 100
            var error: NSError?
            guard JSCCopyChargeHoldStatus(&kind, &limit, &error) else {
                throw error ?? NSError(
                    domain: "com.eclinick.juice.smart-charging",
                    code: 1)
            }

            switch kind.rawValue {
            case 1:
                return SystemChargeHold(kind: .optimized, chargeLimit: limit)
            case 2:
                return SystemChargeHold(kind: .limit, chargeLimit: limit)
            default:
                return nil
            }
        }.value
    }

    private nonisolated static func requestSystemFullCharge() async throws {
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            guard JSCChargeToFull(&error) else {
                throw error ?? NSError(
                    domain: "com.eclinick.juice.smart-charging",
                    code: 2)
            }
        }.value
    }
}
