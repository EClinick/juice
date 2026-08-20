import AppKit
import Foundation
import JuiceSmartChargingBridge

enum OptimizedChargingMode: Equatable, Sendable {
    case disabled
    case enabled
    /// PowerUI state 2: macOS is bypassing an optimized hold to finish the
    /// current charge without changing the persistent preference.
    case chargingToFull
    /// PowerUI state 3: the user temporarily disabled optimized charging.
    case disabledUntilTomorrow

    var switchIsOn: Bool { self == .enabled }
}

enum OptimizedChargingStatus: Equatable, Sendable {
    case loading
    case available(OptimizedChargingMode)
    case unsupported
    case unavailable

    var mode: OptimizedChargingMode? {
        guard case .available(let mode) = self else { return nil }
        return mode
    }
}

enum OptimizedChargingAction: Equatable, Sendable {
    case enable
    case disable
    case disableUntilTomorrow

    var targetMode: OptimizedChargingMode {
        switch self {
        case .enable: .enabled
        case .disable: .disabled
        case .disableUntilTomorrow: .disabledUntilTomorrow
        }
    }
}

/// Keeps Juice's native switch synchronized with the effective state System
/// Settings presents. Reads and writes are injectable so tests never mutate the
/// machine's real charging policy.
@MainActor
final class OptimizedChargingController: ObservableObject {
    static let shared = OptimizedChargingController(
        transactionCoordinator: .shared)

    @Published private(set) var status: OptimizedChargingStatus = .loading
    @Published private(set) var isWriting = false
    @Published private(set) var pendingMode: OptimizedChargingMode?
    @Published private(set) var lastErrorMessage: String?

    var displayedMode: OptimizedChargingMode? {
        pendingMode ?? status.mode
    }

    private let readConfiguration:
        @Sendable () async throws -> OptimizedChargingMode?
    private let writeAction:
        @Sendable (OptimizedChargingAction) async throws -> Void
    private let transactionCoordinator: SmartChargingTransactionCoordinator
    private let openBatterySettingsAction: () -> Void
    private var stateGeneration = 0

    init(
        readConfiguration: (
            @Sendable () async throws -> OptimizedChargingMode?
        )? = nil,
        writeAction: (
            @Sendable (OptimizedChargingAction) async throws -> Void
        )? = nil,
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
        self.writeAction = writeAction
            ?? { try await Self.writeSystemAction($0) }
        let transactionCoordinator = transactionCoordinator
            ?? SmartChargingTransactionCoordinator()
        self.transactionCoordinator = transactionCoordinator
        self.openBatterySettingsAction = openBatterySettingsAction
        transactionCoordinator.register { [weak self] token in
            await self?.reconcile(transaction: token)
        }
    }

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

    func setEnabled(_ enabled: Bool) async {
        await perform(enabled ? .enable : .disable)
    }

    func disableUntilTomorrow() async {
        await perform(.disableUntilTomorrow)
    }

    func openBatterySettings() {
        openBatterySettingsAction()
    }

    private func perform(_ action: OptimizedChargingAction) async {
        guard !isWriting, let currentMode = status.mode else { return }
        if action == .disableUntilTomorrow, currentMode != .enabled {
            return
        }
        guard currentMode != action.targetMode else { return }
        guard let transaction =
                transactionCoordinator.begin(.optimizedCharging)
        else { return }

        lastErrorMessage = nil
        stateGeneration += 1
        isWriting = true
        pendingMode = action.targetMode
        defer {
            isWriting = false
            pendingMode = nil
        }

        var writeWasInvoked = false
        var failureMessage: String?
        var wasCancelled = false
        do {
            try Task.checkCancellation()
            writeWasInvoked = true
            try await writeAction(action)
            try Task.checkCancellation()
        } catch is CancellationError {
            guard writeWasInvoked else {
                transactionCoordinator.cancelBeforeMutation(transaction)
                return
            }
            wasCancelled = true
        } catch {
            failureMessage =
                "Optimized Battery Charging could not be changed."
        }

        await transactionCoordinator.reconcile(transaction)

        guard status.mode != action.targetMode, !wasCancelled else { return }
        if let failureMessage {
            lastErrorMessage = failureMessage
        } else {
            lastErrorMessage = Self.mismatchMessage(for: status.mode)
        }
    }

    private func readResult() async
        -> Result<OptimizedChargingMode?, Error>
    {
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

    private func publish(
        _ result: Result<OptimizedChargingMode?, Error>
    ) {
        switch result {
        case .success(let mode?):
            status = .available(mode)
            lastErrorMessage = nil
        case .success(nil):
            status = .unsupported
            lastErrorMessage = nil
        case .failure:
            status = .unavailable
            lastErrorMessage = nil
        }
    }

    private static func mismatchMessage(
        for mode: OptimizedChargingMode?
    ) -> String {
        switch mode {
        case .enabled:
            "macOS kept Optimized Battery Charging on."
        case .disabled, .disabledUntilTomorrow, .chargingToFull:
            "macOS kept Optimized Battery Charging off."
        case nil:
            "macOS did not return the Optimized Battery Charging setting."
        }
    }

    // MARK: - Dynamic macOS bridge

    private nonisolated static func readSystemConfiguration() async throws
        -> OptimizedChargingMode?
    {
        try await Task.detached(priority: .userInitiated) {
            var supported: ObjCBool = false
            var state = JSCOptimizedChargingState(rawValue: -1)!
            var error: NSError?
            guard JSCCopyOptimizedChargingConfiguration(
                &supported,
                &state,
                &error
            ) else {
                throw error ?? bridgeError(code: 7)
            }
            guard supported.boolValue else { return nil }

            switch state.rawValue {
            case 0: return .disabled
            case 1: return .enabled
            case 2: return .chargingToFull
            case 3: return .disabledUntilTomorrow
            default: throw bridgeError(code: 8)
            }
        }.value
    }

    private nonisolated static func writeSystemAction(
        _ action: OptimizedChargingAction
    ) async throws {
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            let succeeded: Bool
            switch action {
            case .enable:
                succeeded = JSCSetOptimizedChargingEnabled(true, &error)
            case .disable:
                succeeded = JSCSetOptimizedChargingEnabled(false, &error)
            case .disableUntilTomorrow:
                succeeded = JSCTemporarilyDisableOptimizedCharging(&error)
            }
            guard succeeded else {
                throw error ?? bridgeError(code: 9)
            }
        }.value
    }

    private nonisolated static func bridgeError(code: Int) -> NSError {
        NSError(
            domain: "com.eclinick.juice.smart-charging",
            code: code)
    }
}
