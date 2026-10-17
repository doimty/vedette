#include "../libproc/VDTPIDList.h"
#include "../libproc/VDTRulePolicy.h"
#include <assert.h>
#include <stdint.h>

int main(void) {
    int capacity = 0;
    assert(VDTPIDCountFromBytes(-1) == 0);
    assert(VDTPIDCountFromBytes(0) == 0);
    assert(VDTPIDCountFromBytes((int)sizeof(pid_t) - 1) == 0);
    assert(VDTPIDCountFromBytes((int)sizeof(pid_t)) == 1);
    assert(VDTPIDCountFromBytes((int)(4 * sizeof(pid_t))) == 4);

    assert(!VDTCapacityBytesForPIDCount(0, &capacity));
    assert(!VDTCapacityBytesForPIDCount(SIZE_MAX, &capacity));
    assert(!VDTCapacityBytesForPIDCount(1, NULL));
    assert(VDTCapacityBytesForPIDCount(4, &capacity));
    assert(capacity == (int)(4 * sizeof(pid_t)));

    assert(!VDTNeedsPIDSnapshotRetry(-1, capacity));
    assert(!VDTNeedsPIDSnapshotRetry(0, capacity));
    assert(!VDTNeedsPIDSnapshotRetry(capacity - 1, capacity));
    assert(VDTNeedsPIDSnapshotRetry(capacity, capacity));
    assert(VDTNeedsPIDSnapshotRetry(capacity + 1, capacity));
    size_t nextCapacity = 0;
    assert(VDTGrowPIDCapacity(4, &nextCapacity) && nextCapacity == 8);
    assert(!VDTGrowPIDCapacity(0, &nextCapacity));
    assert(!VDTGrowPIDCapacity((size_t)INT_MAX / sizeof(pid_t) / 2 + 1,
                               &nextCapacity));

    const int monitorPolicy = 2;
    const int throttlePolicy = 3;
    assert(VDTResolveCPUAction(true, false, true, monitorPolicy, monitorPolicy,
                               throttlePolicy, 80, 120) == VDTCPUActionNone);
    assert(VDTResolveCPUAction(false, true, true, monitorPolicy, monitorPolicy,
                               throttlePolicy, 80, 120) == VDTCPUActionNone);
    assert(VDTResolveCPUAction(true, true, false, monitorPolicy, monitorPolicy,
                               throttlePolicy, 80, 120) == VDTCPUActionNone);
    assert(VDTResolveCPUAction(true, true, true, 99, monitorPolicy,
                               throttlePolicy, 80, 120) == VDTCPUActionNone);
    assert(VDTResolveCPUAction(true, true, true, monitorPolicy, monitorPolicy,
                               throttlePolicy, 80, 0) == VDTCPUActionNone);
    assert(VDTResolveCPUAction(true, true, true, throttlePolicy, monitorPolicy,
                               throttlePolicy, 0, 120) == VDTCPUActionNone);
    assert(VDTResolveCPUAction(true, true, true, monitorPolicy, monitorPolicy,
                               throttlePolicy, 80, 120) == VDTCPUActionMonitorAndTerminate);
    assert(VDTResolveCPUAction(true, true, true, throttlePolicy, monitorPolicy,
                               throttlePolicy, 60, 120) == VDTCPUActionThrottle);
    return 0;
}
