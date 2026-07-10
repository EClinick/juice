import Foundation

/// A single row from a live process-table snapshot.
///
/// This deliberately carries no power values. Powerlog measures energy at the
/// app-coalition level, while this type only establishes a verified PID tree.
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let cpuPercent: Double
    public let executablePath: String

    public init(pid: Int32, parentPID: Int32, cpuPercent: Double, executablePath: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.cpuPercent = cpuPercent
        self.executablePath = executablePath
    }
}

/// Pure process-tree selection used by the app detail view.
public enum ProcessTree {
    /// Returns each verified root PID and all of its descendants, ordered by
    /// current CPU activity. Empty roots always produce an empty result so a
    /// historical app cannot be associated with an unrelated live process.
    public static func descendants(
        of rootPIDs: Set<Int32>,
        in processes: [ProcessSnapshot]
    ) -> [ProcessSnapshot] {
        guard !rootPIDs.isEmpty else { return [] }

        var selected = rootPIDs
        var changed = true
        while changed {
            changed = false
            for process in processes where selected.contains(process.parentPID) {
                if selected.insert(process.pid).inserted {
                    changed = true
                }
            }
        }

        return processes
            .filter { selected.contains($0.pid) }
            .sorted {
                if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                return $0.pid < $1.pid
            }
    }
}
