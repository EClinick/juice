import Foundation

/// Runs a child process with an absolute path and an argv array - never a shell
/// string - under a hard deadline, draining both pipes concurrently.
///
/// Both properties matter to Juice: the helper runs as root and must not be
/// parked forever on a `pmset` that never exits, and reading one pipe to EOF
/// before touching the other deadlocks if the child fills the other's buffer
/// first.
public enum BoundedProcess {
    /// Exit status plus captured output.
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The child did not exit within the deadline and was terminated.
        case timedOut(seconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "the command timed out after \(Self.text(seconds)) seconds and was terminated"
            }
        }

        private static func text(_ seconds: TimeInterval) -> String {
            String(format: seconds < 1 ? "%.2f" : "%.0f", seconds)
        }
    }

    /// How long a terminated child gets to die before it is killed outright.
    static let terminationGrace: TimeInterval = 1

    /// Spawns `executable`, waits up to `deadline` seconds for it, and returns
    /// its status and output. Throws ``Failure/timedOut(seconds:)`` after
    /// terminating (then killing) a child that overstays.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        deadline: TimeInterval
    ) throws -> Result {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        // A semaphore rather than waitUntilExit(): only the termination handler
        // gives the wait a deadline.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let out = PipeDrain(outPipe)
        let err = PipeDrain(errPipe)
        try process.run()

        let drained = DispatchGroup()
        let queue = DispatchQueue(
            label: "\(JuiceXPC.helperLabel).bounded-process", attributes: .concurrent)
        queue.async(group: drained, execute: out.drain)
        queue.async(group: drained, execute: err.drain)

        if exited.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
            // The pipes close as the child dies, so the drains end on their own;
            // the bound only guards against a stray descriptor inheritor.
            _ = drained.wait(timeout: .now() + terminationGrace)
            throw Failure.timedOut(seconds: deadline)
        }

        drained.wait()
        return Result(status: process.terminationStatus, stdout: out.text, stderr: err.text)
    }
}

/// Reads one pipe to EOF on a background queue. Owns its file handle so the
/// concurrent read never has to capture a non-Sendable value.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
    }

    func drain() {
        let read = (try? handle.readToEnd()) ?? nil
        lock.lock()
        data = read ?? Data()
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
