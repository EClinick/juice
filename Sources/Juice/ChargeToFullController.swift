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
    private let requestFullCharge:
        @Sendable () async throws -> SystemChargeHold
    private let transactionCoordinator: SmartChargingTransactionCoordinator
    private let now: () -> Date
    private var generation = 0
    private var acceptedAt: Date?
    private var acceptedReconciliationGeneration: Int?
    private var acceptedPolicyReconciliationGeneration: Int?
    private var lastReading: BatteryReading?
    private var confirmationTask: Task<Void, Never>?

    static let confirmationGrace: TimeInterval = 10

    init(
        readStatus: (@Sendable () async throws -> SystemChargeHold?)? = nil,
        requestFullCharge: (
            @Sendable () async throws -> SystemChargeHold
        )? = nil,
        transactionCoordinator: SmartChargingTransactionCoordinator? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.readStatus = readStatus ?? { try await Self.readSystemStatus() }
        self.requestFullCharge = requestFullCharge ?? {
            try await Self.requestSystemFullCharge()
        }
        self.transactionCoordinator = transactionCoordinator
            ?? SmartChargingTransactionCoordinator()
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
        guard !transactionCoordinator.isMutating else { return }
        let transactionEpoch = transactionCoordinator.epoch

        let result: Result<SystemChargeHold?, any Error>
        do {
            result = .success(try await readStatus())
        } catch {
            result = .failure(error)
        }
        guard generation == refreshGeneration,
              transactionEpoch == transactionCoordinator.epoch,
              !transactionCoordinator.isMutating,
              !isRequesting
        else { return }

        apply(result, reading: reading)
    }

    private func apply(
        _ result: Result<SystemChargeHold?, any Error>,
        reading: BatteryReading?
    ) {
        // PowerUI and IOKit do not update atomically, so an ordinary immediate
        // re-read cannot erase a successful request. A later Settings
        // transaction is different: its authoritative hold read wins when the
        // hold disappeared or changed, while a matching hold (or read failure)
        // preserves the short confirmation grace.
        if case .accepted(let acceptedReason) = state, transitionIsFresh {
            let reconciliationGeneration =
                transactionCoordinator.reconciliationGeneration
            guard acceptedReconciliationGeneration
                    != reconciliationGeneration else { return }
            switch result {
            case .failure:
                return
            case .success(let hold?):
                let policyGeneration =
                    transactionCoordinator.reconciliationGeneration(
                        for: Self.mutationKind(for: acceptedReason))
                let samePolicyChanged =
                    acceptedPolicyReconciliationGeneration != policyGeneration
                if !samePolicyChanged,
                   Self.hold(hold, matches: acceptedReason) {
                    acceptedReconciliationGeneration =
                        reconciliationGeneration
                    return
                }
            case .success(nil):
                break
            }
        }

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
        let initialMutationKind = Self.mutationKind(for: reason)
        guard let transaction =
                transactionCoordinator.begin(initialMutationKind)
        else {
            return false
        }

        generation += 1
        isRequesting = true
        state = .starting(reason)
        var requestWasInvoked = false
        var effectiveReason = reason
        var effectiveMutationKind = initialMutationKind

        do {
            try Task.checkCancellation()
            requestWasInvoked = true
            let actedHold = try await requestFullCharge()
            guard let actedReason = Self.reason(
                for: actedHold,
                reading: lastReading
            ) else {
                throw ChargeToFullRequestError.invalidActedHold
            }
            effectiveReason = actedReason
            effectiveMutationKind = Self.mutationKind(for: actedReason)
            await transactionCoordinator.reconcile(
                transaction,
                mutationKind: effectiveMutationKind)
            generation += 1
            isRequesting = false
            if Self.couldBeActionable(lastReading) {
                acceptedAt = now()
                acceptedReconciliationGeneration =
                    transactionCoordinator.reconciliationGeneration
                acceptedPolicyReconciliationGeneration =
                    transactionCoordinator.reconciliationGeneration(
                        for: effectiveMutationKind)
                state = .accepted(effectiveReason)
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
                await transactionCoordinator.reconcile(
                    transaction,
                    mutationKind: effectiveMutationKind)
            } else {
                transactionCoordinator.cancelBeforeMutation(transaction)
                state = .ready(reason)
            }
            return false
        } catch {
            let authoritativeResult: Result<SystemChargeHold?, any Error>?
            if requestWasInvoked {
                // The action performs its own hold read. A stale popover can
                // therefore reach this path because the hold disappeared before
                // any override selector was invoked. Re-read while the shared
                // transaction is still held so a stale reason never becomes a
                // retry button.
                authoritativeResult = await readStatusResult()
                await transactionCoordinator.reconcile(
                    transaction,
                    mutationKind: effectiveMutationKind)
            } else {
                authoritativeResult = nil
                transactionCoordinator.cancelBeforeMutation(transaction)
            }
            generation += 1
            isRequesting = false
            clearAcceptedTransition()
            // A battery refresh can arrive while the private request is in
            // flight. Do not restore a retry for a hold that became ineligible
            // in the meantime (for example, after unplugging).
            if requestWasInvoked,
               Self.couldBeActionable(lastReading),
               case .success(let hold?) = authoritativeResult,
               let freshReason = Self.reason(for: hold, reading: lastReading) {
                state = .failed(freshReason)
            } else if !requestWasInvoked,
                      Self.couldBeActionable(lastReading) {
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

        let result = await readStatusResult()
        guard generation == refreshGeneration, !isRequesting else { return }
        apply(result, reading: reading)
    }

    private func readStatusResult() async
        -> Result<SystemChargeHold?, any Error>
    {
        let reader = readStatus
        return await Task.detached(priority: .userInitiated) {
            do {
                return .success(try await reader())
            } catch {
                return .failure(error)
            }
        }.value
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
        acceptedReconciliationGeneration = nil
        acceptedPolicyReconciliationGeneration = nil
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

    private static func mutationKind(
        for reason: ChargeToFullReason
    ) -> SmartChargingTransactionCoordinator.MutationKind {
        switch reason {
        case .optimized:
            .optimizedCharging
        case .limit:
            .chargeLimit
        }
    }

    private static func hold(
        _ hold: SystemChargeHold,
        matches reason: ChargeToFullReason
    ) -> Bool {
        switch (hold.kind, reason) {
        case (.optimized, .optimized):
            return true
        case (.limit, .limit(let percent)):
            return hold.chargeLimit == percent
        default:
            return false
        }
    }

    private enum ChargeToFullRequestError: Error {
        case invalidActedHold
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

    private nonisolated static func requestSystemFullCharge() async throws
        -> SystemChargeHold
    {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            var kind = JSCChargeHoldKind(rawValue: 0)!
            var limit = 100
            var error: NSError?
            guard JSCChargeToFull(&kind, &limit, &error) else {
                throw error ?? NSError(
                    domain: "com.eclinick.juice.smart-charging",
                    code: 2)
            }
            switch kind.rawValue {
            case 1:
                return SystemChargeHold(
                    kind: .optimized,
                    chargeLimit: limit)
            case 2:
                return SystemChargeHold(kind: .limit, chargeLimit: limit)
            default:
                throw ChargeToFullRequestError.invalidActedHold
            }
        }.value
    }
}
