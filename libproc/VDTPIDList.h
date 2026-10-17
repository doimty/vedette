#ifndef VDT_PID_LIST_H
#define VDT_PID_LIST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <sys/types.h>

static inline size_t VDTPIDCountFromBytes(int byteCount) {
    if (byteCount <= 0 || (size_t)byteCount % sizeof(pid_t) != 0) return 0;
    return (size_t)byteCount / sizeof(pid_t);
}

static inline bool VDTCapacityBytesForPIDCount(size_t pidCount, int *byteCapacity) {
    if (!byteCapacity || pidCount == 0 || pidCount > (size_t)INT_MAX / sizeof(pid_t))
        return false;
    *byteCapacity = (int)(pidCount * sizeof(pid_t));
    return true;
}

static inline bool VDTNeedsPIDSnapshotRetry(int returnedBytes, int byteCapacity) {
    return returnedBytes > 0 && byteCapacity > 0 && returnedBytes >= byteCapacity;
}

static inline bool VDTGrowPIDCapacity(size_t currentCapacity, size_t *nextCapacity) {
    size_t maximumCapacity = (size_t)INT_MAX / sizeof(pid_t);
    if (!nextCapacity || currentCapacity == 0 || currentCapacity > maximumCapacity / 2)
        return false;
    *nextCapacity = currentCapacity * 2;
    return true;
}

#endif
