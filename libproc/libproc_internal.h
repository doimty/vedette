#ifndef LIBPROC_LIBPROC_INTERNAL_H
#define LIBPROC_LIBPROC_INTERNAL_H

#include <sys/cdefs.h>
#include <stdint.h>
#include <sys/types.h>

#define PROC_ALL_PIDS 1
#define PROC_SETCPU_ACTION_THROTTLE 1
#define VDT_PROC_PIDTBSDINFO 3

// ABI-compatible subset used to bind a PID to one process lifetime. The layout
// matches Darwin's proc_bsdinfo from <sys/proc_info.h>.
struct vdt_proc_bsdinfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uid_t pbi_uid;
    gid_t pbi_gid;
    uid_t pbi_ruid;
    gid_t pbi_rgid;
    uid_t pbi_svuid;
    gid_t pbi_svgid;
    uint32_t rfu_1;
    char pbi_comm[16];
    char pbi_name[32];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t e_tdev;
    uint32_t e_tpgid;
    int32_t pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
};

#if defined(__cplusplus) && __cplusplus < 201103L
// The production/native fixtures also support GNU C++98. Keep the same hard
// ABI assertion without requiring the C++11 static_assert keyword.
typedef char vdt_proc_bsdinfo_abi_must_be_136[(sizeof(struct vdt_proc_bsdinfo) == 136) ? 1 : -1];
#elif defined(__cplusplus)
static_assert(sizeof(struct vdt_proc_bsdinfo) == 136, "unexpected proc_bsdinfo ABI");
#else
_Static_assert(sizeof(struct vdt_proc_bsdinfo) == 136, "unexpected proc_bsdinfo ABI");
#endif

__BEGIN_DECLS
int proc_name(int pid, void *buffer, uint32_t buffersize);
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_disable_cpumon(int pid);
int proc_set_cpumon_params_fatal(int pid, int percentage, int interval);
int proc_set_cpumon_defaults(int pid);
int proc_resume_cpumon(int pid);
int proc_setcpu_percentage(int pid, int action, int percentage);
int proc_clear_cpulimits(int pid);
__END_DECLS

#endif
