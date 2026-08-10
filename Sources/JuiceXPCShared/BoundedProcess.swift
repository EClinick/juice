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

    /// How long past its deadline a run may spend waiting for the pipes to
    /// close. A descendant that inherited the write ends holds them open for
    /// its own lifetime, so this wait must be bounded even on the success path.
    static let drainGrace: TimeInterval = 0.5

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
        let start = DispatchTime.now()
        try process.run()

        let drained = DispatchGroup()
        let queue = DispatchQueue(
            label: "\(JuiceXPC.helperLabel).bounded-process", attributes: .concurrent)
        queue.async(group: drained, execute: out.drain)
        queue.async(group: drained, execute: err.drain)

        if exited.wait(timeout: start + deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
            finishDraining(drained, [out, err], budget: drainGrace)
            throw Failure.timedOut(seconds: deadline)
        }

        // The child is gone, but the pipes only reach EOF once every process
        // holding a write end has exited - a `sh -c 'sleep 30 &'` descendant
        // inherits them and would otherwise park this call for 30 s. Whatever
        // was captured by the time the deadline runs out is what the caller
        // gets: the deadline is a promise about wall clock, not about output.
        finishDraining(drained, [out, err], budget: remaining(from: start, deadline: deadline))
        return Result(status: process.terminationStatus, stdout: out.text, stderr: err.text)
    }

    /// Seconds left of `deadline`, plus the drain grace; never negative.
    private static func remaining(from start: DispatchTime, deadline: TimeInterval) -> TimeInterval {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        return max(deadline - elapsed, 0) + drainGrace
    }

    /// Waits up to `budget` for both drains to finish, then stops them so no
    /// reader outlives the call by more than one poll interval.
    private static func finishDraining(
        _ drained: DispatchGroup,
        _ drains: [PipeDrain],
        budget: TimeInterval
    ) {
        guard drained.wait(timeout: .now() + budget) == .timedOut else { return }
        for drain in drains { drain.stop() }
    }
}

/// Reads one pipe to EOF on a background queue. Owns its file handle so the
/// concurrent read never has to capture a non-Sendable value.
///
/// The read loop polls instead of blocking in `readToEnd()`: a blocking read
/// can only be unblocked by closing the descriptor underneath it, which races
/// the reader, whereas a poll timeout lets ``stop()`` end the loop cleanly.
private final class PipeDrain: @unchecked Sendable {
    /// How long a poll waits before rechecking ``stop()``. Short enough that a
    /// stopped drain does not outlive its run, long enough to be free while the
    /// child is actually writing (a readable pipe returns immediately).
    private static let pollInterval: Int32 = 25
    private static let bufferSize = 64 * 1024

    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var stopped = false

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
    }

    func drain() {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        while !isStopped {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, Self.pollInterval)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            // EOF: every write end is closed, so the child and any descendant
            // that inherited them are done.
            if count == 0 { return }
            append(buffer, count: count)
        }
    }

    /// Ends the read loop. The captured output stays readable; only further
    /// reading stops.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func append(_ buffer: [UInt8], count: Int) {
        lock.lock()
        data.append(contentsOf: buffer[0..<count])
        lock.unlock()
    }
}
