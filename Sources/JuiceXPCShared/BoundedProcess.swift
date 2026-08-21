import Foundation
import Darwin

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

        var output = PipeCollector(stdout: outPipe, stderr: errPipe)
        let start = DispatchTime.now()
        try process.run()

        if !output.waitForExit(exited, until: start + deadline) {
            process.terminate()
            if !output.waitForExit(exited, until: .now() + terminationGrace) {
                kill(process.processIdentifier, SIGKILL)
                _ = output.waitForExit(exited, until: .now() + terminationGrace)
            }
            output.drain(until: .now() + drainGrace)
            throw Failure.timedOut(seconds: deadline)
        }

        // The child is gone, but the pipes only reach EOF once every process
        // holding a write end has exited - a `sh -c 'sleep 30 &'` descendant
        // inherits them and would otherwise park this call for 30 s. Whatever
        // was captured by the time the deadline runs out is what the caller
        // gets: the deadline is a promise about wall clock, not about output.
        output.drain(until: .now() + remaining(from: start, deadline: deadline))
        return Result(
            status: process.terminationStatus,
            stdout: output.stdoutText,
            stderr: output.stderrText)
    }

    /// Seconds left of `deadline`, plus the drain grace; never negative.
    private static func remaining(from start: DispatchTime, deadline: TimeInterval) -> TimeInterval {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        return max(deadline - elapsed, 0) + drainGrace
    }
}

/// Multiplexes stdout and stderr on the calling thread so draining never
/// depends on a background worker being scheduled before the deadline. Each
/// ready descriptor contributes at most one chunk per poll, preventing a busy
/// stream from starving the other.
private struct PipeCollector {
    /// How long a poll waits before rechecking the process-exit semaphore.
    private static let pollInterval: Int32 = 25
    private static let bufferSize = 64 * 1024
    private static let requestedEvents = Int16(POLLIN)

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutAtEOF = false
    private var stderrAtEOF = false

    init(stdout: Pipe, stderr: Pipe) {
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
    }

    /// Drains both pipes while waiting for the direct child to exit. Polling on
    /// this thread keeps a child that fills either pipe able to make progress.
    mutating func waitForExit(
        _ exited: DispatchSemaphore,
        until deadline: DispatchTime
    ) -> Bool {
        while true {
            if exited.wait(timeout: .now()) == .success { return true }

            let timeout = Self.timeout(until: deadline)
            guard timeout > 0 else {
                pollOnce(timeout: 0)
                return exited.wait(timeout: .now()) == .success
            }
            pollOnce(timeout: timeout)
        }
    }

    /// Drains until every writer closes or the absolute bound arrives. One
    /// final nonblocking poll captures bytes already buffered at the boundary.
    mutating func drain(until deadline: DispatchTime) {
        while !atEOF {
            let timeout = Self.timeout(until: deadline)
            guard timeout > 0 else { break }
            pollOnce(timeout: timeout)
        }
        pollOnce(timeout: 0)
    }

    var stdoutText: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    var stderrText: String {
        String(decoding: stderrData, as: UTF8.self)
    }

    private var atEOF: Bool {
        stdoutAtEOF && stderrAtEOF
    }

    private static func timeout(until deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return 0 }

        let remaining = deadline.uptimeNanoseconds - now
        let milliseconds = (remaining + 999_999) / 1_000_000
        return min(pollInterval, Int32(clamping: milliseconds))
    }

    private mutating func pollOnce(timeout: Int32) {
        var events = [
            pollfd(
                fd: stdoutAtEOF ? -1 : stdoutHandle.fileDescriptor,
                events: Self.requestedEvents,
                revents: 0),
            pollfd(
                fd: stderrAtEOF ? -1 : stderrHandle.fileDescriptor,
                events: Self.requestedEvents,
                revents: 0),
        ]
        let ready = events.withUnsafeMutableBufferPointer {
            poll($0.baseAddress, nfds_t($0.count), timeout)
        }
        guard ready > 0 else { return }

        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        if events[0].revents != 0 {
            Self.read(
                stdoutHandle.fileDescriptor,
                into: &stdoutData,
                atEOF: &stdoutAtEOF,
                buffer: &buffer)
        }
        if events[1].revents != 0 {
            Self.read(
                stderrHandle.fileDescriptor,
                into: &stderrData,
                atEOF: &stderrAtEOF,
                buffer: &buffer)
        }
    }

    private static func read(
        _ descriptor: Int32,
        into data: inout Data,
        atEOF: inout Bool,
        buffer: inout [UInt8]
    ) {
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count > 0 {
            data.append(contentsOf: buffer[0..<count])
        } else if count == 0 {
            // EOF means the child and every descendant holding this write end
            // have closed it.
            atEOF = true
        } else if errno != EINTR && errno != EAGAIN {
            // A permanent read error cannot become useful output later.
            atEOF = true
        }
    }
}
