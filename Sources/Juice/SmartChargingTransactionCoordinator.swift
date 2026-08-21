import Foundation

/// Serializes every private PowerUI mutation and owns the epoch shared by all
/// smart-charging readers. A write stays active until every registered setting
/// has completed an authoritative readback, because one setting can alter the
/// other's temporary state.
@MainActor
final class SmartChargingTransactionCoordinator: ObservableObject {
    enum MutationKind: Equatable {
        case chargeLimit
        case optimizedCharging
    }

    struct Token: Equatable {
        fileprivate let id: UUID
        fileprivate let epoch: Int
        fileprivate let kind: MutationKind
    }

    static let shared = SmartChargingTransactionCoordinator()

    @Published private(set) var isMutating = false
    @Published private(set) var reconciliationGeneration = 0
    private(set) var epoch = 0
    private var chargeLimitReconciliationGeneration = 0
    private var optimizedChargingReconciliationGeneration = 0

    private var activeToken: Token?
    private var reconcilers: [
        UUID: @MainActor (Token) async -> Void
    ] = [:]

    @discardableResult
    func register(
        _ reconcile: @escaping @MainActor (Token) async -> Void
    ) -> UUID {
        let id = UUID()
        reconcilers[id] = reconcile
        return id
    }

    func begin(_ kind: MutationKind) -> Token? {
        guard activeToken == nil else { return nil }
        epoch &+= 1
        let token = Token(id: UUID(), epoch: epoch, kind: kind)
        activeToken = token
        isMutating = true
        return token
    }

    func reconciliationGeneration(for kind: MutationKind) -> Int {
        switch kind {
        case .chargeLimit:
            chargeLimitReconciliationGeneration
        case .optimizedCharging:
            optimizedChargingReconciliationGeneration
        }
    }

    func isCurrent(_ token: Token) -> Bool {
        activeToken == token && epoch == token.epoch
    }

    /// Re-reads all registered setting surfaces before releasing the write
    /// lane. The generation changes only after those readbacks complete, so
    /// the popover never refreshes against a half-reconciled settings model.
    func reconcile(
        _ token: Token,
        mutationKind: MutationKind? = nil
    ) async {
        guard isCurrent(token) else { return }
        let callbacks = Array(reconcilers.values)
        for callback in callbacks {
            guard isCurrent(token) else { return }
            await callback(token)
        }
        guard isCurrent(token) else { return }
        activeToken = nil
        isMutating = false
        switch mutationKind ?? token.kind {
        case .chargeLimit:
            chargeLimitReconciliationGeneration &+= 1
        case .optimizedCharging:
            optimizedChargingReconciliationGeneration &+= 1
        }
        reconciliationGeneration &+= 1
    }

    /// Releases a transaction that was cancelled before its system mutation
    /// began. Starting the transaction already advanced the epoch, so stale
    /// reads remain invalid without pretending a system change occurred.
    func cancelBeforeMutation(_ token: Token) {
        guard isCurrent(token) else { return }
        activeToken = nil
        isMutating = false
    }
}
