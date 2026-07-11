#include "JuiceHelperCoalition.h"

#include <string.h>
#include <errno.h>
#include <libproc.h>
#include <sys/proc_info.h>

// The coalition APIs are private: neither <sys/proc_info.h> nor <mach/coalition.h>
// ship the struct/flavor/constant definitions in the public SDK, so we declare
// exactly what the kernel expects. Layout verified empirically on macOS 26
// (Darwin 25.x) arm64 and against apple-oss-distributions/xnu osfmk/mach/coalition.h.

// proc_pidinfo flavor for the per-pid coalition membership.
#define JUICE_PROC_PIDCOALITIONINFO 20

// COALITION_TYPE_RESOURCE is index 0 of the per-type arrays; COALITION_NUM_TYPES
// is 2 (RESOURCE, JETSAM). We over-size the arrays to 4 slots: proc_pidinfo
// returns 40 bytes for this flavor, and a struct sized to only 2 types is too
// small and yields a zeroed coalition id. Reading id[0] gives the resource
// coalition regardless.
#define JUICE_COALITION_TYPE_RESOURCE 0
#define JUICE_COALITION_TASKROLE_LEADER 1

struct juice_proc_pidcoalitioninfo {
    uint64_t coalition_id[4];
    uint32_t coalition_type[4];
    uint32_t coalition_role[4];
};

// struct coalition_resource_usage, exact field order from xnu
// osfmk/mach/coalition.h. Only cpu `energy`, `gpu_energy_nj`, and `ane_energy_nj`
// are consumed; the rest exist to place those fields at the right offsets.
// cpu_time_eqos is [7] (NOT [8]); getting that wrong shifts every field after
// it. A generous trailing pad tolerates the kernel appending fields in future
// OS versions: the syscall truncates its write to our reported buffer size.
struct juice_coalition_resource_usage {
    uint64_t tasks_started;
    uint64_t tasks_exited;
    uint64_t time_nonempty;
    uint64_t cpu_time;
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;
    uint64_t byteswritten;
    uint64_t gpu_time;
    uint64_t cpu_time_billed_to_me;
    uint64_t cpu_time_billed_to_others;
    uint64_t energy;                 // CPU energy (nJ)
    uint64_t logical_immediate_writes;
    uint64_t logical_deferred_writes;
    uint64_t logical_invalidated_writes;
    uint64_t logical_metadata_writes;
    uint64_t logical_immediate_writes_to_external;
    uint64_t logical_deferred_writes_to_external;
    uint64_t logical_invalidated_writes_to_external;
    uint64_t logical_metadata_writes_to_external;
    uint64_t energy_billed_to_me;
    uint64_t energy_billed_to_others;
    uint64_t cpu_ptime;
    uint64_t cpu_time_eqos_len;
    uint64_t cpu_time_eqos[7];
    uint64_t cpu_instructions;
    uint64_t cpu_cycles;
    uint64_t fs_metadata_writes;
    uint64_t pm_writes;
    uint64_t cpu_pinstructions;
    uint64_t cpu_pcycles;
    uint64_t conclave_mem;
    uint64_t ane_mach_time;
    uint64_t ane_energy_nj;          // ANE energy (nJ)
    uint64_t phys_footprint;
    uint64_t gpu_energy_nj;          // GPU energy (nJ)
    uint64_t gpu_energy_nj_billed_to_me;
    uint64_t gpu_energy_nj_billed_to_others;
    uint64_t swapins;
    uint64_t _forward_compat_pad[64];
};

// Private wrapper exported from libsystem_kernel (xnu
// libsyscall/wrappers/coalition.c). Using it instead of raw syscall(2) avoids
// the deprecated-syscall warning and leaves the syscall number, which shifts
// between OS releases, to Apple's own libc.
extern int coalition_info_resource_usage(uint64_t cid, void *cru, size_t sz);

int juice_proc_coalition(int32_t pid, JuiceProcCoalition *out) {
    struct juice_proc_pidcoalitioninfo info;
    memset(&info, 0, sizeof(info));
    errno = 0;
    int rc = proc_pidinfo(pid, JUICE_PROC_PIDCOALITIONINFO, 0, &info, (int)sizeof(info));
    if (rc <= 0) {
        return errno != 0 ? errno : -1;
    }
    out->coalitionID = info.coalition_id[JUICE_COALITION_TYPE_RESOURCE];
    out->isLeader = (info.coalition_role[JUICE_COALITION_TYPE_RESOURCE] == JUICE_COALITION_TASKROLE_LEADER) ? 1 : 0;
    return 0;
}

int juice_coalition_resource_usage(uint64_t coalitionID, JuiceCoalitionUsage *out) {
    struct juice_coalition_resource_usage cru;
    memset(&cru, 0, sizeof(cru));
    errno = 0;
    int rc = coalition_info_resource_usage(coalitionID, &cru, sizeof(cru));
    if (rc != 0) {
        return errno != 0 ? errno : -1;
    }
    out->cpuEnergyNJ = cru.energy;
    out->gpuEnergyNJ = cru.gpu_energy_nj;
    out->aneEnergyNJ = cru.ane_energy_nj;
    return 0;
}
