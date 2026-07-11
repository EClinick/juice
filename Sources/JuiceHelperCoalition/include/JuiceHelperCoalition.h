#ifndef JUICE_HELPER_COALITION_H
#define JUICE_HELPER_COALITION_H

#include <stdint.h>

/// Cumulative energy counters for one resource coalition, in nanojoules.
///
/// These come from the private coalition_info(COALITION_INFO_RESOURCE_USAGE)
/// syscall. `cpu`, `gpu`, and `ane` are three independent SoC-energy domains;
/// the app sums them for a per-app total. Counters are monotonic and cumulative
/// since the coalition was formed, so the app differentiates snapshots itself.
typedef struct {
    uint64_t cpuEnergyNJ;
    uint64_t gpuEnergyNJ;
    uint64_t aneEnergyNJ;
} JuiceCoalitionUsage;

/// The resource coalition a process belongs to.
///
/// Resource coalitions carry no per-task role (leadership is a jetsam-coalition
/// concept), so callers pick a representative process themselves.
typedef struct {
    uint64_t coalitionID;
} JuiceProcCoalition;

/// Reads the resource-coalition id for `pid`.
///
/// Returns 0 on success. On failure returns the errno-style code (or -1 for an
/// unexpected short read) and leaves `*out` untouched; a PID that vanishes
/// between enumeration and this call fails here rather than fabricating a row.
int juice_proc_coalition(int32_t pid, JuiceProcCoalition *out);

/// Reads cumulative energy for one resource coalition id.
///
/// Returns 0 on success. On failure returns the errno from the syscall (e.g.
/// EINVAL for a coalition id that no longer exists) and leaves `*out` untouched.
/// No privilege is required for COALITION_INFO_RESOURCE_USAGE (the xnu handler
/// has no credential check), so this works for every coalition on the system.
int juice_coalition_resource_usage(uint64_t coalitionID, JuiceCoalitionUsage *out);

#endif /* JUICE_HELPER_COALITION_H */
