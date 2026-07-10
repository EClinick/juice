import AppKit
import Foundation
import JuiceCore

/// A live process associated with an app's running process tree.
///
/// Powerlog reports energy for an app coalition rather than individual PIDs.
/// These snapshots connect that coalition to the processes that are running
/// now, which makes the detail view useful without pretending that historical
/// PID-level power data exists.
struct AppProcess: Identifiable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let executablePath: String
    let cpuPercent: Double
    let isRootProcess: Bool

    var id: Int32 { pid }

    var role: String {
        isRootProcess ? "Main app process" : "Child of PID \(parentPID)"
    }
}

enum AppProcessLoadResult: Sendable {
    case loaded([AppProcess])
    case timedOut
}

/// Resolves a running app to its PID and descendant processes using the
/// system process table. The bundle lookup supplies an exact root PID for
/// normal apps. A command-name fallback is limited to known system coalitions
/// that have no app bundle.
enum AppProcessInspector {
    private static let systemCoalitionKeys: Set<String> = [
        "windowserver",
        "com.apple.windowserver",
        "kernel_task",
        "com.apple.kernel_task"
    ]

    @MainActor
    static func rootPIDs(for appKey: String) -> Set<Int32> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == appKey }
                .map(\.processIdentifier)
                .filter { $0 > 0 }
        )
    }

    /// Returns the app's root process and every running descendant. This
    /// intentionally performs no power attribution: `ps` exposes a live CPU
    /// snapshot only, while energy remains a historical coalition total.
    static func processes(appKey: String, rootPIDs: Set<Int32>) -> AppProcessLoadResult {
        let allProcesses: [ProcessSnapshot]
        switch processTable() {
        case .loaded(let processes):
            allProcesses = processes
        case .timedOut:
            return .timedOut
        }
        guard !allProcesses.isEmpty else { return .loaded([]) }

        let roots = rootPIDs.isEmpty
            ? systemCoalitionRootPIDs(for: appKey, in: allProcesses)
            : rootPIDs

        guard !roots.isEmpty else { return .loaded([]) }

        return .loaded(ProcessTree.descendants(of: roots, in: allProcesses)
            .map {
                AppProcess(
                    pid: $0.pid,
                    parentPID: $0.parentPID,
                    name: URL(fileURLWithPath: $0.executablePath).lastPathComponent,
                    executablePath: $0.executablePath,
                    cpuPercent: $0.cpuPercent,
                    isRootProcess: roots.contains($0.pid)
                )
            })
    }

    private static func systemCoalitionRootPIDs(
        for appKey: String,
        in processes: [ProcessSnapshot]
    ) -> Set<Int32> {
        let key = appKey.lowercased()
        guard systemCoalitionKeys.contains(key) else { return [] }

        let expectedName = key.contains("windowserver") ? "windowserver" : "kernel_task"
        return Set(processes.compactMap { process in
            let executable = URL(fileURLWithPath: process.executablePath)
                .lastPathComponent
                .lowercased()
            return executable == expectedName ? process.pid : nil
        })
    }

    private enum ProcessTableResult {
        case loaded([ProcessSnapshot])
        case timedOut
    }

    private final class ProcessTimeout: @unchecked Sendable {
        private let lock = NSLock()
        private var didFire = false

        func fire() {
            lock.lock()
            didFire = true
            lock.unlock()
        }

        var hasFired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didFire
        }
    }

    private static func processTable() -> ProcessTableResult {
        let process = Process()
        let output = Pipe()
        let timeout = ProcessTimeout()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pcpu=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .loaded([])
        }

        deadline.schedule(deadline: .now() + 3)
        deadline.setEventHandler {
            if process.isRunning {
                timeout.fire()
                process.terminate()
            }
        }
        deadline.resume()

        // Read before waiting. On machines with a large process table, `ps`
        // can fill the pipe buffer and block forever if its output is only
        // drained after `waitUntilExit()` returns.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        if timeout.hasFired {
            return .timedOut
        }

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else {
            return .loaded([])
        }

        return .loaded(text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard columns.count == 4,
                  let pid = Int32(columns[0]),
                  let parentPID = Int32(columns[1]),
                  let cpuPercent = Double(columns[2])
            else {
                return nil
            }

            return ProcessSnapshot(
                pid: pid,
                parentPID: parentPID,
                cpuPercent: max(0, cpuPercent),
                executablePath: String(columns[3])
            )
        })
    }
}
