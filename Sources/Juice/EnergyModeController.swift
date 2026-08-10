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
    static let pmsetPath = "/usr/bin/pmset"

    private let readState: @Sendable () async -> PowerModeState?
    private let writeState: @Sendable (PowerMode, PowerModeScope) async throws -> PowerModeState
    private let defaults: UserDefaults
    private var highPowerUnsupported: Bool

    /// The readers and writers are injectable seams: the state machine is
    /// covered by tests without root, a real helper, or a real `pmset`.
    init(
        defaults: UserDefaults? = nil,
        readState: (@Sendable () async -> PowerModeState?)? = nil,
        writeState: (@Sendable (PowerMode, PowerModeScope) async throws -> PowerModeState)? = nil
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: JuiceXPC.defaultsSuiteName)
            ?? .standard
        self.readState = readState ?? { await Self.readSystemState() }
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
        let fresh = await readState()
        state = fresh
        if fresh != nil {
            lastErrorMessage = nil
        }
    }

    /// Writes `mode` for the power source currently in use. Writing only the
    /// active source mirrors System Settings, which keeps the two sources'
    /// modes independent.
    func set(_ mode: PowerMode, onAC: Bool) async {
        guard !isWriting else { return }
        isWriting = true
        pendingMode = mode
        defer {
            isWriting = false
            pendingMode = nil
        }

        do {
            let applied = try await writeState(mode, onAC ? .ac : .battery)
            state = applied
            lastErrorMessage = nil
            needsHelperUpdate = false
        } catch HelperClientError.helperOutdated {
            needsHelperUpdate = true
        } catch is CancellationError {
            return
        } catch {
            let code = HelperError.code(of: error)
            let refusedHighPower = mode == .highPower
                && (code == .unsupportedPowerMode || code == .powerSettingFailed)
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
            guard let output = runPMSetCustom() else { return nil }
            return try? PowerModeParser.parse(pmsetCustomOutput: output)
        }.value
    }

    /// Absolute path and an argv array, never a shell string.
    private nonisolated static func runPMSetCustom() -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g", "custom"]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain both pipes before waiting so verbose output cannot fill a pipe
        // buffer and deadlock the wait.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: outData, as: UTF8.self)
    }
}
