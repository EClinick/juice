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

    /// Longest a whole read/write/read-back transaction may run before the
    /// helper gives up on it. `pmset` returns in milliseconds, so anything near
    /// this is wedged, and the budget is shared by every command in the
    /// transaction - the two reads and however many writes the machine's key
    /// layout needs: the client's own timeout covers the transaction, not one
    /// command of it.
    static let transactionDeadline: TimeInterval = 10

    /// Longest a transaction waits for the one ahead of it. Beyond this the
    /// caller is better off told the machine is busy than left holding an XPC
    /// reply until its own timeout fires.
    static let lockTimeout: TimeInterval = 2

    /// Process-wide, because every XPC connection gets its own ``HelperService``
    /// and therefore its own writer: a per-instance lock would still let a
    /// client that timed out and retried on a fresh connection interleave its
    /// read/write/read-back transaction with the original one.
    private static let transactionLock = NSLock()

    /// Injectable so tests can cover validation, legacy-key handling, and
    /// read-back verification without root. The deadline is part of the seam
    /// because it is the budget left for that one command, not a constant.
    private let runCommand: (String, [String], TimeInterval) throws -> CommandResult
    /// Instance-level so a test can prove the busy path without waiting out the
    /// production timeout; production always uses ``lockTimeout``.
    private let lockWait: TimeInterval

    /// Instance-level for the same reason as ``lockWait``: tests prove the
    /// exhausted-budget path with a tiny budget instead of waiting out 10 s.
    private let transactionBudget: TimeInterval

    init(
        runCommand: @escaping (String, [String], TimeInterval) throws -> CommandResult
            = PowerModeWriter.spawn,
        lockWait: TimeInterval = PowerModeWriter.lockTimeout,
        transactionBudget: TimeInterval = PowerModeWriter.transactionDeadline
    ) {
        self.runCommand = runCommand
        self.lockWait = lockWait
        self.transactionBudget = transactionBudget
    }

    /// Reads the machine's current Energy Mode. Unprivileged.
    func readState() throws -> PowerModeState {
        try readState(deadline: Self.transactionDeadline)
    }

    private func readState(deadline: TimeInterval) throws -> PowerModeState {
        let result = try runCommand(Self.pmsetPath, ["-g", "custom"], deadline)
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
        // wait for the transaction ahead is bounded too, because an unbounded
        // one plus three bounded commands can outlast the client's own timeout,
        // which would leave the machine changing after the caller gave up.
        guard Self.transactionLock.lock(before: Date().addingTimeInterval(lockWait)) else {
            throw HelperError.error(
                .powerSettingFailed, message: "another Energy Mode change is in progress")
        }
        defer { Self.transactionLock.unlock() }
        // The budget starts once the lock is held, so a transaction is never
        // charged for time it spent queued.
        return try apply(mode: mode, scope: scope, budget: Budget(seconds: transactionBudget))
    }

    /// What is left of one transaction's wall clock, shared by its commands.
    private struct Budget {
        private let expiry: Date

        init(seconds: TimeInterval) {
            expiry = Date().addingTimeInterval(seconds)
        }

        /// The time left for the next command, or an error once the budget is
        /// spent. Checked before EVERY spawn: a privileged write must never
        /// start after the transaction's deadline has already passed, or the
        /// machine can change after the client gave up and reported failure.
        func remainingOrThrow(before step: String) throws -> TimeInterval {
            let left = max(expiry.timeIntervalSinceNow, 0)
            guard left > 0 else {
                throw HelperError.error(
                    .powerSettingFailed,
                    message: "transaction deadline passed before the \(step)")
            }
            return left
        }
    }

    private func apply(
        mode: PowerMode,
        scope: PowerModeScope,
        budget: Budget
    ) throws -> PowerModeState {
        // Which keys exist is a hardware property, so it must be discovered
        // before writing rather than assumed.
        let before = try readState(
            deadline: budget.remainingOrThrow(before: "initial read"))
        // Derived before anything is spawned, so a mode this machine cannot
        // express is refused rather than half-written.
        let plan = try Self.writePlan(mode: mode, scope: scope, layout: before.keyLayout)

        for arguments in plan {
            let write = try runCommand(
                Self.pmsetPath, arguments, budget.remainingOrThrow(before: "write"))
            guard write.status == 0 else {
                throw HelperError.error(
                    .powerSettingFailed,
                    message: "pmset exited \(write.status): \(Self.detail(write.stderr))")
            }
        }

        // pmset exits 0 for values the hardware silently declines, so the
        // read-back is the only honest confirmation.
        let after = try readState(
            deadline: budget.remainingOrThrow(before: "verification read"))
        for applied in Self.affectedScopes(scope) where after.mode(for: applied) != mode {
            // A High Power write that pmset accepted and the machine dropped is
            // hardware refusal - but only if nothing moved: System Settings or
            // another client writing between the write and the read-back leaves
            // the same mismatch, and blaming the hardware for that would hide
            // High Power for good. Hardware refusal is the unchanged case.
            let unchanged = after.mode(for: applied) == before.mode(for: applied)
            let refused = mode == .highPower && unchanged
            throw HelperError.error(
                refused ? .unsupportedPowerMode : .powerSettingFailed,
                message: "pmset accepted the change but \(applied.rawValue) reports mode "
                    + "\(after.mode(for: applied)?.rawValue ?? -1)"
                    + (unchanged
                        ? ", unchanged from before the write"
                        : "; something else changed Energy Mode during the write"))
        }
        return after
    }

    /// The `pmset` invocations that put `scope` into `mode` on a machine whose
    /// keys are laid out as `layout`, in the order they must run.
    ///
    /// A dual-boolean machine expresses no mode with a single key, so both are
    /// always written and the machine is never left with only half the answer.
    /// The key being cleared goes first: nothing then observes `lowpowermode`
    /// and `highpowermode` set at once, and a transaction cut short mid-plan
    /// leaves the more conservative of the two states rather than a contradiction.
    private static func writePlan(
        mode: PowerMode,
        scope: PowerModeScope,
        layout: PowerModeKeyLayout
    ) throws -> [[String]] {
        func command(_ key: String, _ value: Int) -> [String] {
            [scope.pmsetFlag, key, String(value)]
        }

        switch layout {
        case .unified:
            return [command("powermode", mode.rawValue)]
        case .lowPowerOnly:
            guard mode != .highPower else {
                throw HelperError.error(
                    .unsupportedPowerMode,
                    message: "this Mac only supports Automatic and Low Power")
            }
            return [command("lowpowermode", mode == .lowPower ? 1 : 0)]
        case .dualBoolean:
            switch mode {
            case .automatic:
                return [command("lowpowermode", 0), command("highpowermode", 0)]
            case .lowPower:
                return [command("highpowermode", 0), command("lowpowermode", 1)]
            case .highPower:
                return [command("lowpowermode", 0), command("highpowermode", 1)]
            }
        }
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

    /// Runs `executable` with an argv array and waits for it, up to `deadline`.
    /// Absolute path and array arguments only: no shell is involved at any
    /// point. The deadline is a parameter so a transaction can pass what is left
    /// of its budget, and so tests can prove the timeout path without waiting
    /// out the production one.
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
