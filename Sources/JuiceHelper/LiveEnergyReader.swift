import Foundation
import Darwin
import JuiceXPCShared
import JuiceHelperCoalition

/// Enumerates every readable process, groups them into resource coalitions, and
/// reads each coalition's cumulative energy counters, producing one stateless
/// `LiveEnergySnapshot`.
///
/// Energy is metered per resource coalition via the private
/// coalition_info(COALITION_INFO_RESOURCE_USAGE) syscall (wrapped in the C shim
/// `JuiceHelperCoalition`). The plain `energy` field is CPU energy; GPU and ANE
/// are separate counters. All are nanojoules, cumulative, monotonic. The reader
/// never differentiates; the app computes watts from deltas between snapshots.
///
/// Per-PID rusage billed-energy was the previous source but reads 0 for the
/// process doing the work, so it is unusable as a live signal; coalition
/// accounting is what Activity Monitor and powermetrics coalition mode use.
struct LiveEnergyReader {
    /// Reads a full snapshot. Runs as root so it can see every PID; the
    /// coalition syscall itself needs no privilege.
    func snapshot() -> LiveEnergySnapshot {
        let pids = Self.allPIDs()

        // Group PIDs by resource coalition, tracking a leader per coalition.
        // Leader preference: the pid whose role is coalition leader; failing
        // that (leader not visible), the lowest pid seen in the coalition.
        struct Group {
            var leaderPID: Int32
            var leaderIsAuthoritative: Bool
        }
        var groups: [UInt64: Group] = [:]
        groups.reserveCapacity(pids.count)

        for pid in pids {
            // Skip the kernel: its coalition is not an app.
            guard pid > 0 else { continue }
            // A PID that vanishes between listing and reading fails here; drop
            // it rather than fabricating a row.
            var membership = JuiceProcCoalition()
            guard juice_proc_coalition(pid, &membership) == 0 else { continue }

            let cid = membership.coalitionID
            let isLeader = membership.isLeader != 0

            if var existing = groups[cid] {
                if isLeader, !existing.leaderIsAuthoritative {
                    // A real leader always wins over a lowest-pid placeholder.
                    existing.leaderPID = pid
                    existing.leaderIsAuthoritative = true
                } else if isLeader == existing.leaderIsAuthoritative, pid < existing.leaderPID {
                    // Same authority tier: keep the lowest pid for determinism.
                    existing.leaderPID = pid
                }
                groups[cid] = existing
            } else {
                groups[cid] = Group(leaderPID: pid, leaderIsAuthoritative: isLeader)
            }
        }

        // Read energy once per unique coalition and resolve the leader path.
        var samples: [LiveEnergySample] = []
        samples.reserveCapacity(groups.count)

        for (cid, group) in groups {
            var usage = JuiceCoalitionUsage()
            // A coalition that emptied out between grouping and this read returns
            // an error (e.g. EINVAL); drop it.
            guard juice_coalition_resource_usage(cid, &usage) == 0 else { continue }

            let path = Self.executablePath(group.leaderPID) ?? ""

            samples.append(
                LiveEnergySample(
                    coalitionID: cid,
                    leaderPID: group.leaderPID,
                    leaderPath: path,
                    cpuEnergyNJ: usage.cpuEnergyNJ,
                    gpuEnergyNJ: usage.gpuEnergyNJ,
                    aneEnergyNJ: usage.aneEnergyNJ
                )
            )
        }

        return LiveEnergySnapshot(
            timestampEpoch: Date().timeIntervalSince1970,
            samples: samples
        )
    }

    // MARK: - proc_* wrappers

    private static func allPIDs() -> [Int32] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Over-allocate: the process count can grow between the sizing call
        // and the fill call.
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let byteCount = Int32(pids.count) * Int32(MemoryLayout<Int32>.size)
        let written = proc_listallpids(&pids, byteCount)
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count))
    }

    private static func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4*MAXPATHLEN; the macro is not imported
        // into Swift, so size the buffer directly (MAXPATHLEN == PATH_MAX).
        let capacity = 4 * Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }
}
