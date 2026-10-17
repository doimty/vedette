#ifndef VDT_RULE_POLICY_H
#define VDT_RULE_POLICY_H

#include <stdbool.h>

typedef enum {
    VDTCPUActionNone = 0,
    VDTCPUActionMonitorAndTerminate,
    VDTCPUActionThrottle
} VDTCPUAction;

static inline VDTCPUAction VDTResolveCPUAction(bool globalEnabled,
                                                bool hasMatchingRule,
                                                bool processEnabled,
                                                int policy,
                                                int monitorAndTerminatePolicy,
                                                int throttlePolicy,
                                                int percentage,
                                                int interval) {
    if (!globalEnabled || !hasMatchingRule || !processEnabled) return VDTCPUActionNone;
    if (policy == monitorAndTerminatePolicy && percentage > 0 && interval > 0)
        return VDTCPUActionMonitorAndTerminate;
    if (policy == throttlePolicy && percentage > 0)
        return VDTCPUActionThrottle;
    return VDTCPUActionNone;
}

#endif
