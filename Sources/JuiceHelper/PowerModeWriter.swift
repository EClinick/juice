import Foundation
import JuiceXPCShared

/// Applies macOS Energy Mode changes via `pmset`, the only supported interface
/// for `powermode`, and the security boundary for the helper's first mutating
/// operation.
///
/// Every value crossing XPC is re-validated here against the closed
/// ``PowerMode``/``PowerModeScope`` enums, and the command is always spawned
/// from an absolute path with an argv array, never a shell string, so a hostile
/// caller cannot smuggle arguments or metacharacters into a root process.
struct PowerModeWriter {
    /// Result of running a command: exit status plus captured output.
    typealias CommandResult = (status: Int32, stdout: String, stderr: String)

    static let pmsetPath = "/usr/bin/pmset"

    /// Longest a `pmset` invocation may run before the helper gives up on it.
    /// `pmset` returns in milliseconds; anything near this is wedged, and a root
    /// process must not be parked on it forever.
    static let commandDeadline: TimeInterval = 10

    /// Process-wide, because every XPC connection gets its own ``HelperService``
    /// and therefore its own writer: a per-instance lock would still let a
    /// client that timed out and retried on a fresh connection interleave its
    /// read/write/read-back transaction with the original one.
    private static let transactionLock = NSLock()

    /// Injectable so tests can cover validation, legacy-key handling, and
    /// read-back verification without root.
    private let runCommand: (String, [String]) throws -> CommandResult

    init(runCommand: @escaping (String, [String]) throws -> CommandResult = PowerModeWriter.spawn) {
        self.runCommand = runCommand
    }

    /// Reads the machine's current Energy Mode. Unprivileged.
    func readState() throws -> PowerModeState {
        let result = try runCommand(Self.pmsetPath, ["-g", "custom"])
        guard result.status == 0 else {
            throw HelperError.error(
                .internalError,
                message: "pmset -g custom exited \(result.status): \(Self.detail(result.stderr))")
        }
        do {
            return try PowerModeParser.parse(pmsetCustomOutput: result.stdout)
        } catch {
            throw HelperError.error(.internalError, message: error.localizedDescription)
        }
    }

    /// Validates, writes, and verifies an Energy Mode change, returning the
    /// state read back after the write.
    func setPowerMode(rawMode: Int, rawScope: String) throws -> PowerModeState {
        guard let mode = PowerMode(rawValue: rawMode) else {
            throw HelperError.error(
                .unsupportedPowerMode, message: "unknown power mode \(rawMode)")
        }
        guard let scope = PowerModeScope(rawValue: rawScope) else {
            throw HelperError.error(
                .unsupportedPowerMode, message: "unknown power mode scope '\(rawScope)'")
        }

        // Read, write, and read-back are one transaction: two overlapping calls
        // would otherwise verify each other's writes and report nonsense. The
        // spawns are deadline-bounded, so the wait here is bounded too.
        Self.transactionLock.lock()
        defer { Self.transactionLock.unlock() }
        return try apply(mode: mode, scope: scope)
    }

    private func apply(mode: PowerMode, scope: PowerModeScope) throws -> PowerModeState {
        // Which key exists is a hardware property, so it must be discovered
        // before writing rather than assumed.
        let before = try readState()
        guard !(before.usesLegacyLowPowerKey && mode == .highPower) else {
            throw HelperError.error(
                .unsupportedPowerMode,
                message: "this Mac only supports Automatic and Low Power")
        }

        let write = try runCommand(
            Self.pmsetPath, [scope.pmsetFlag, before.pmsetKey, String(mode.rawValue)])
        guard write.status == 0 else {
            throw HelperError.error(
                .powerSettingFailed,
                message: "pmset exited \(write.status): \(Self.detail(write.stderr))")
        }

        // pmset exits 0 for values the hardware silently declines, so the
        // read-back is the only honest confirmation.
        let after = try readState()
        for applied in Self.affectedScopes(scope) where after.mode(for: applied) != mode {
            // A High Power write that pmset accepted and the machine dropped is
            // hardware refusal, not a transient failure: it is the only signal
            // the app has that this Mac has no High Power at all. Every other
            // mismatch stays transient so a one-off failure is retryable.
            throw HelperError.error(
                mode == .highPower ? .unsupportedPowerMode : .powerSettingFailed,
                message: "pmset accepted the change but \(applied.rawValue) still reports "
                    + "mode \(after.mode(for: applied)?.rawValue ?? -1)")
        }
        return after
    }

    /// The individual power sources a scope writes, so `.all` is verified on
    /// both rather than only where the two happen to agree.
    private static func affectedScopes(_ scope: PowerModeScope) -> [PowerModeScope] {
        switch scope {
        case .battery: return [.battery]
        case .ac: return [.ac]
        case .all: return [.battery, .ac]
        }
    }

    private static func detail(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no stderr output" : trimmed
    }

    /// Runs `executable` with an argv array and waits for it. Absolute path and
    /// array arguments only: no shell is involved at any point.
    static func spawn(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try spawn(executable, arguments, deadline: commandDeadline)
    }

    /// The deadline is a parameter so tests can prove the timeout path without
    /// waiting out the production deadline.
    static func spawn(
        _ executable: String,
        _ arguments: [String],
        deadline: TimeInterval
    ) throws -> CommandResult {
        do {
            let result = try BoundedProcess.run(executable, arguments, deadline: deadline)
            return (status: result.status, stdout: result.stdout, stderr: result.stderr)
        } catch let failure as BoundedProcess.Failure {
            throw HelperError.error(
                .powerSettingFailed,
                message: "\(([executable] + arguments).joined(separator: " ")): "
                    + failure.localizedDescription)
        }
    }
}
