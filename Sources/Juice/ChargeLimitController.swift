import AppKit
import Foundation
import JuiceSmartChargingBridge

enum ChargeLimitSelection: Equatable, Sendable {
    case persistent(Int)
    /// PowerUI intentionally hides the saved limit while a one-time full charge
    /// is active, so no persistent percentage is representable in this state.
    case chargingToFull

    var persistentLimit: Int? {
        guard case .persistent(let limit) = self else { return nil }
        return limit
    }
}

/// The manual charging policy macOS currently exposes to Juice.
struct ChargeLimitConfiguration: Equatable, Sendable {
    let selection: ChargeLimitSelection
    let availableLimits: [Int]
}

enum ChargeLimitStatus: Equatable, Sendable {
    case loading
    case available(ChargeLimitConfiguration)
    case unsupported
    case unavailable

    var configuration: ChargeLimitConfiguration? {
        guard case .available(let configuration) = self else { return nil }
        return configuration
    }
}

/// Keeps the Settings picker synchronized with macOS's persistent Charge Limit.
/// Reads and writes use the same dynamic PowerUI bridge as Charge to Full, but
/// are injectable so tests never change the machine's real charging policy.
@MainActor
final class ChargeLimitController: ObservableObject {
    static let shared = ChargeLimitController(
        transactionCoordinator: .shared)

    @Published private(set) var status: ChargeLimitStatus = .loading
    @Published private(set) var isWriting = false
    @Published private(set) var pendingLimit: Int?
    @Published private(set) var lastErrorMessage: String?

    var displayedLimit: Int? {
        pendingLimit ?? status.configuration?.selection.persistentLimit
    }

    private let readConfiguration:
        @Sendable () async throws -> ChargeLimitConfiguration?
    private let writeLimit: @Sendable (Int) async throws -> Void
    private let openBatterySettingsAction: () -> Void
    private let transactionCoordinator: SmartChargingTransactionCoordinator
    /// Invalidates a read that began before a newer write started or finished.
    private var stateGeneration = 0

    init(
        readConfiguration: (
            @Sendable () async throws -> ChargeLimitConfiguration?
        )? = nil,
        writeLimit: (@Sendable (Int) async throws -> Void)? = nil,
        transactionCoordinator: SmartChargingTransactionCoordinator? = nil,
        openBatterySettingsAction: @escaping () -> Void = {
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.Battery-Settings.extension")
            else { return }
            NSWorkspace.shared.open(url)
        }
    ) {
        self.readConfiguration = readConfiguration
            ?? { try await Self.readSystemConfiguration() }
        self.writeLimit = writeLimit
            ?? { try await Self.writeSystemLimit($0) }
        let transactionCoordinator = transactionCoordinator
            ?? SmartChargingTransactionCoordinator()
        self.transactionCoordinator = transactionCoordinator
        self.openBatterySettingsAction = openBatterySettingsAction
        transactionCoordinator.register { [weak self] token in
            await self?.reconcile(transaction: token)
        }
    }

    /// Re-reads macOS instead of caching the value in Juice preferences. A
    /// refresh that races a write is discarded so it cannot roll the picker
    /// back to a stale limit.
    func refresh() async {
        guard !isWriting, !transactionCoordinator.isMutating else { return }
        stateGeneration += 1
        let refreshGeneration = stateGeneration
        let transactionEpoch = transactionCoordinator.epoch
        let result = await readResult()
        guard refreshGeneration == stateGeneration,
              transactionEpoch == transactionCoordinator.epoch,
              !isWriting,
              !transactionCoordinator.isMutating
        else { return }
        publish(result)
    }

    func setLimit(_ limit: Int) async {
        guard !isWriting,
              let configuration = status.configuration,
              configuration.availableLimits.contains(limit)
        else { return }

        lastErrorMessage = nil
        guard configuration.selection != .persistent(limit) else { return }
        guard let transaction = transactionCoordinator.begin(.chargeLimit)
        else { return }

        stateGeneration += 1
        isWriting = true
        pendingLimit = limit
        defer {
            isWriting = false
            pendingLimit = nil
        }

        var writeWasInvoked = false
        var failureMessage: String?
        var wasCancelled = false

        do {
            try Task.checkCancellation()
            writeWasInvoked = true
            try await writeLimit(limit)
            // Awaiting a detached system call does not cancel the call itself.
            // If this view disappeared while it ran, reconcile rather than
            // publishing an unverified requested value.
            try Task.checkCancellation()
        } catch is CancellationError {
            guard writeWasInvoked else {
                transactionCoordinator.cancelBeforeMutation(transaction)
                return
            }
            wasCancelled = true
        } catch {
            // A failed private call can still cross the process boundary.
            // Re-read before displaying an error so the picker remains honest.
            failureMessage = "Charge Limit could not be changed."
        }

        await transactionCoordinator.reconcile(transaction)

        guard let configuration = status.configuration,
              configuration.selection != .persistent(limit),
              !wasCancelled
        else { return }
        if let failureMessage {
            lastErrorMessage = failureMessage
        } else {
            lastErrorMessage = Self.mismatchMessage(for: configuration)
        }
    }

    func openBatterySettings() {
        openBatterySettingsAction()
    }

    private func readResult() async -> Result<ChargeLimitConfiguration?, Error> {
        let reader = readConfiguration
        return await Task.detached(priority: .userInitiated) {
            do {
                return .success(try await reader())
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func reconcile(
        transaction: SmartChargingTransactionCoordinator.Token
    ) async {
        let result = await readResult()
        guard transactionCoordinator.isCurrent(transaction) else { return }
        stateGeneration += 1
        publish(result)
    }

    private static func mismatchMessage(
        for configuration: ChargeLimitConfiguration
    ) -> String {
        switch configuration.selection {
        case .persistent(let limit):
            return "macOS kept the Charge Limit at \(limit)%."
        case .chargingToFull:
            return "macOS is still charging to full for this session."
        }
    }

    private func publish(
        _ result: Result<ChargeLimitConfiguration?, Error>
    ) {
        switch result {
        case .success(let configuration?):
            status = .available(configuration)
            lastErrorMessage = nil
        case .success(nil):
            status = .unsupported
            lastErrorMessage = nil
        case .failure:
            status = .unavailable
            lastErrorMessage = nil
        }
    }

    // MARK: - Dynamic macOS bridge

    private nonisolated static func readSystemConfiguration() async throws
        -> ChargeLimitConfiguration?
    {
        try await Task.detached(priority: .userInitiated) {
            var supported: ObjCBool = false
            var currentLimit = 100
            var available = JSCChargeLimitOptions(rawValue: 0)
            var state = JSCChargeLimitState(rawValue: -1)!
            var error: NSError?
            guard JSCCopyChargeLimitConfiguration(
                &supported,
                &currentLimit,
                &available,
                &state,
                &error
            ) else {
                throw error ?? bridgeError(code: 3)
            }
            guard supported.boolValue else { return nil }

            let knownOptions: [(limit: Int, bit: UInt)] = [
                (80, 1 << 0),
                (85, 1 << 1),
                (90, 1 << 2),
                (95, 1 << 3),
                (100, 1 << 4),
            ]
            let limits = knownOptions.compactMap { option in
                available.rawValue & option.bit == 0 ? nil : option.limit
            }
            guard limits.contains(currentLimit) else {
                throw bridgeError(code: 4)
            }
            let selection: ChargeLimitSelection
            switch state.rawValue {
            case 0, 1:
                selection = .persistent(currentLimit)
            case 3:
                selection = .chargingToFull
            default:
                throw bridgeError(code: 6)
            }
            return ChargeLimitConfiguration(
                selection: selection,
                availableLimits: limits)
        }.value
    }

    private nonisolated static func writeSystemLimit(_ limit: Int) async throws {
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            guard JSCSetChargeLimit(limit, &error) else {
                throw error ?? bridgeError(code: 5)
            }
        }.value
    }

    private nonisolated static func bridgeError(code: Int) -> NSError {
        NSError(
            domain: "com.eclinick.juice.smart-charging",
            code: code)
    }
}
