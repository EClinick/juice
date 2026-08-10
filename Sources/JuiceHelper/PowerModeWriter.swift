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
            throw HelperError.error(
                .powerSettingFailed,
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
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        // pmset returns promptly; read both pipes before waiting so a verbose
        // failure cannot fill a pipe buffer and deadlock the helper.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}
