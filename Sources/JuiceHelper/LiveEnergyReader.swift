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

        // Group PIDs by resource coalition. Resource coalitions have no
        // leader role in the kernel, so the lowest PID represents the
        // coalition: in an app coalition the main app process spawned first,
        // and even when it has exited, any surviving helper's path still
        // resolves to the same .app bundle.
        var groups: [UInt64: Int32] = [:]
        groups.reserveCapacity(pids.count)

        for pid in pids {
            // Skip the kernel: its coalition is not an app.
            guard pid > 0 else { continue }
            // A PID that vanishes between listing and reading fails here; drop
            // it rather than fabricating a row.
            var membership = JuiceProcCoalition()
            guard juice_proc_coalition(pid, &membership) == 0 else { continue }

            let cid = membership.coalitionID
            if let existing = groups[cid], existing <= pid { continue }
            groups[cid] = pid
        }

        // Read energy once per unique coalition and resolve the leader path.
        var samples: [LiveEnergySample] = []
        samples.reserveCapacity(groups.count)

        for (cid, leaderPID) in groups {
            var usage = JuiceCoalitionUsage()
            // A coalition that emptied out between grouping and this read returns
            // an error (e.g. EINVAL); drop it.
            guard juice_coalition_resource_usage(cid, &usage) == 0 else { continue }

            let path = Self.executablePath(leaderPID) ?? ""

            samples.append(
                LiveEnergySample(
                    coalitionID: cid,
                    leaderPID: leaderPID,
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
        // proc_listallpids returns a PID COUNT from both the sizing call and
        // the fill call (unlike proc_listpids, which returns bytes) - verified
        // empirically; dividing by the element size here would drop 3/4 of
        // the process table.
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Over-allocate: the process count can grow between the sizing call
        // and the fill call.
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let byteCount = Int32(pids.count) * Int32(MemoryLayout<Int32>.size)
        let written = proc_listallpids(&pids, byteCount)
        guard written > 0 else { return [] }
        let count = min(Int(written), pids.count)
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
