#ifndef LIBPROC_LIBPROC_INTERNAL_H
#define LIBPROC_LIBPROC_INTERNAL_H

#include <sys/cdefs.h>
#include <stdint.h>
#include <sys/types.h>

#define PROC_ALL_PIDS 1
#define PROC_SETCPU_ACTION_THROTTLE 1

__BEGIN_DECLS
int proc_name(int pid, void *buffer, uint32_t buffersize);
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_disable_cpumon(int pid);
int proc_set_cpumon_params_fatal(int pid, int percentage, int interval);
int proc_set_cpumon_defaults(int pid);
int proc_resume_cpumon(int pid);
int proc_setcpu_percentage(int pid, int action, int percentage);
int proc_clear_cpulimits(int pid);
__END_DECLS

#endif
