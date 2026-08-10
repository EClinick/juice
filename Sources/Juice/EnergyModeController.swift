import Foundation
import JuiceXPCShared

extension PowerMode {
    /// The name macOS uses for this mode in System Settings.
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .lowPower: return "Low Power"
        case .highPower: return "High Power"
        }
    }
}

/// Owns the popover's Energy Mode state: an unprivileged `pmset -g custom` read
/// plus writes routed through the privileged helper.
///
/// Reads are cheap and never need root, so the controller can re-read whenever
/// the popover opens. Writes are the app's only mutating helper call, and the
/// only reliable way to learn that a machine refuses High Power is to attempt it
/// and see the helper's read-back verification fail. That answer is a hardware
/// property, so it is cached in defaults and the option is then hidden for good.
@MainActor
final class EnergyModeController: ObservableObject {
    /// The configured mode per power source, or nil while unavailable: the read
    /// failed, or this Mac has no "Battery Power:" section at all (a desktop).
    @Published private(set) var state: PowerModeState?
    @Published private(set) var isWriting = false
    /// True once a write has been refused by a helper that predates protocol
    /// version 4. Only relaunching the app can install the newer helper.
    @Published private(set) var needsHelperUpdate = false
    /// Transient, human-readable failure text. Cleared by the next successful
    /// read or write.
    @Published private(set) var lastErrorMessage: String?
    /// The mode whose write is in flight, so the picker can show progress on
    /// exactly the button that was pressed.
    @Published private(set) var pendingMode: PowerMode?

    /// Whether the High Power option should be offered at all.
    var showsHighPower: Bool {
        guard let state else { return false }
        return !state.usesLegacyLowPowerKey && !highPowerUnsupported
    }

    static let highPowerUnsupportedKey = "energyMode.highPowerUnsupported.v1"
    /// Read by the detached reader, so it cannot be actor-isolated.
    nonisolated static let pmsetPath = "/usr/bin/pmset"
    /// `pmset -g custom` answers in milliseconds; a read that outlives this is
    /// wedged and the popover is better off with no Energy Mode UI than a hang.
    nonisolated static let readDeadline: TimeInterval = 5

    private let readState: @Sendable () async -> PowerModeState?
    private let writeState: @Sendable (PowerMode, PowerModeScope) async throws -> PowerModeState
    private let currentOnAC: @Sendable () -> Bool?
    private let defaults: UserDefaults
    private var highPowerUnsupported: Bool
    /// Bumped by every write that publishes state, so a refresh that started
    /// earlier can tell its answer is now stale and drop it.
    private var stateGeneration = 0

    /// The readers and writers are injectable seams: the state machine is
    /// covered by tests without root, a real helper, or a real `pmset`.
    init(
        defaults: UserDefaults? = nil,
        readState: (@Sendable () async -> PowerModeState?)? = nil,
        writeState: (@Sendable (PowerMode, PowerModeScope) async throws -> PowerModeState)? = nil,
        currentOnAC: (@Sendable () -> Bool?)? = nil
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: JuiceXPC.defaultsSuiteName)
            ?? .standard
        self.readState = readState ?? { await Self.readSystemState() }
        // IOKit, not the battery view model's ~60 s timer: the source in use at
        // the moment of the write is the only one worth writing.
        self.currentOnAC = currentOnAC ?? { (try? BatteryMonitor.read())?.onAC }
        if let writeState {
            self.writeState = writeState
        } else {
            let client = HelperClient()
            self.writeState = { mode, scope in
                try await client.setPowerMode(mode, scope: scope)
            }
        }
        highPowerUnsupported = self.defaults.bool(forKey: Self.highPowerUnsupportedKey)
    }

    /// Re-reads the machine's Energy Mode. Quiet on failure: an unreadable or
    /// battery-less machine simply has no Energy Mode UI.
    func refresh() async {
        let generation = stateGeneration
        let fresh = await readState()
        // A write that landed while this read was in flight is newer than the
        // answer being held, and must not be rolled back by it.
        guard generation == stateGeneration else { return }
        state = fresh
        if fresh != nil {
            lastErrorMessage = nil
        }
    }

    /// Forgets a previously detected outdated helper, so the notice does not
    /// outlive an upgrade that happened while the app ran. The next write
    /// re-detects it if the installed helper is still too old.
    func helperMayHaveUpdated() {
        needsHelperUpdate = false
    }

    /// Writes `mode` for the power source currently in use. Writing only the
    /// active source mirrors System Settings, which keeps the two sources'
    /// modes independent.
    ///
    /// `onAC` is the caller's view of the power source; a fresher live reading
    /// wins when one is available, because plugging in moments before a tap must
    /// not send the write to the source that is no longer in use.
    func set(_ mode: PowerMode, onAC: Bool) async {
        guard !isWriting else { return }
        isWriting = true
        pendingMode = mode
        defer {
            isWriting = false
            pendingMode = nil
        }

        let scope: PowerModeScope = (currentOnAC() ?? onAC) ? .ac : .battery
        do {
            let applied = try await writeState(mode, scope)
            stateGeneration += 1
            state = applied
            lastErrorMessage = nil
            needsHelperUpdate = false
        } catch HelperClientError.helperOutdated {
            needsHelperUpdate = true
        } catch is CancellationError {
            return
        } catch {
            // Only an accepted-then-dropped High Power write proves the hardware
            // has no High Power. A transient failure must never hide the option
            // for good, so it is reported and left retryable.
            let refusedHighPower = mode == .highPower
                && HelperError.code(of: error) == .unsupportedPowerMode
            // Re-read either way: a failed write may still have moved the
            // machine, and the UI must never show a mode that is not set.
            await refresh()
            if refusedHighPower {
                cacheHighPowerUnsupported()
                lastErrorMessage = "This Mac does not support High Power."
            } else {
                lastErrorMessage = Self.message(for: error)
            }
        }
    }

    private func cacheHighPowerUnsupported() {
        highPowerUnsupported = true
        defaults.set(true, forKey: Self.highPowerUnsupportedKey)
    }

    private static func message(for error: Error) -> String {
        if let clientError = error as? HelperClientError, case .timedOut = clientError {
            return "The helper did not respond in time."
        }
        switch HelperError.code(of: error) {
        case .unsupportedPowerMode:
            return "This Mac does not support that Energy Mode."
        case .powerSettingFailed:
            return "macOS did not apply the new Energy Mode."
        default:
            return "Energy Mode could not be changed."
        }
    }

    // MARK: - Unprivileged read

    /// Spawns `pmset -g custom` off the main actor: the popover must never block
    /// its run loop on a process, however brief.
    private nonisolated static func readSystemState() async -> PowerModeState? {
        await Task.detached(priority: .userInitiated) {
            // Absolute path and an argv array, never a shell string; both pipes
            // drained concurrently, and the whole read on a deadline.
            guard
                let result = try? BoundedProcess.run(
                    pmsetPath, ["-g", "custom"], deadline: readDeadline),
                result.status == 0
            else {
                return nil
            }
            return try? PowerModeParser.parse(pmsetCustomOutput: result.stdout)
        }.value
    }
}
