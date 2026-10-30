// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#ifndef VDT_PID_SNAPSHOT_H
#define VDT_PID_SNAPSHOT_H

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// proc_listpids uses native int PID entries and byte counts, NOT element counts.
// A NULL buffer/zero capacity is the estimate query. The callback reports an
// error separately: zero bytes with error == 0 is a valid empty result; negative
// bytes or a nonzero error is failure. A read returning its entire capacity is
// possibly truncated, so only a strictly smaller, aligned read is complete.
typedef int (*VDTPIDSnapshotListReader)(int *buffer, int capacityBytes,
                                      int *outError, void *context);
// The allocator must return storage aligned for int; release matches allocate.
typedef void *(*VDTPIDSnapshotAllocator)(size_t bytes, void *context);
typedef void (*VDTPIDSnapshotDeallocator)(void *buffer, void *context);

typedef struct {
    VDTPIDSnapshotListReader listPIDs;
    VDTPIDSnapshotAllocator allocate;
    VDTPIDSnapshotDeallocator deallocate;
    void *context;
} VDTPIDSnapshotOperations;

typedef struct {
    // Owned by the caller only on nonempty success; release with the supplied
    // deallocator. Empty success and every failure leave pids NULL/count zero.
    int *pids;
    size_t count;
    // Enumeration only: not an atomic process lifetime/identity snapshot.
    bool complete;
    // Positive errno on failure; zero on success. No partial snapshot escapes.
    int error;
} VDTPIDSnapshot;

enum {
    VDTPIDSnapshotMinimumCapacity = 128,
    VDTPIDSnapshotHeadroom = 32,
    VDTPIDSnapshotMaxPIDs = 65536, // 256 KiB on the production 32-bit PID ABI.
    VDTPIDSnapshotReadLimit = 6   // Initial read plus at most five growth retries.
};

// Executes the production enumeration kernel without Foundation or libproc.
// Capacity starts at the estimate plus 25% (at least 32 PIDs) of headroom and
// doubles after a full read. Both the allocation and libproc's signed byte
// argument are bounded; only one buffer is live at a time. There is no polling,
// sleeping, timer or retry of a failed syscall. EINVAL means malformed sizes or
// operations, E2BIG means the capacity/byte bound, EAGAIN means repeated full
// reads, ENOMEM means allocation failure, and EIO substitutes missing errno.
static inline VDTPIDSnapshot VDTCopyPIDSnapshot(const VDTPIDSnapshotOperations *operations) {
    VDTPIDSnapshot snapshot = {NULL, 0, false, 0};
    if (!operations || !operations->listPIDs || !operations->allocate || !operations->deallocate) {
        snapshot.error = EINVAL;
        return snapshot;
    }

    int scanError = 0;
    int queryBytes = operations->listPIDs(NULL, 0, &scanError, operations->context);
    if (queryBytes < 0 || scanError != 0) {
        snapshot.error = scanError > 0 ? scanError : EIO;
        return snapshot;
    }
    if ((size_t)queryBytes % sizeof(int) != 0) {
        snapshot.error = EINVAL;
        return snapshot;
    }

    size_t maxCapacity = (size_t)VDTPIDSnapshotMaxPIDs;
    if (maxCapacity > SIZE_MAX / sizeof(int)) maxCapacity = SIZE_MAX / sizeof(int);
    if (maxCapacity > (size_t)INT_MAX / sizeof(int)) maxCapacity = (size_t)INT_MAX / sizeof(int);
    size_t reportedCount = (size_t)queryBytes / sizeof(int);
    if (maxCapacity == 0 || reportedCount > maxCapacity) {
        snapshot.error = E2BIG;
        return snapshot;
    }

    size_t headroom = reportedCount / 4;
    if (headroom < VDTPIDSnapshotHeadroom) headroom = VDTPIDSnapshotHeadroom;
    size_t capacity = headroom > maxCapacity - reportedCount ? maxCapacity : reportedCount + headroom;
    if (capacity < VDTPIDSnapshotMinimumCapacity) {
        capacity = maxCapacity < VDTPIDSnapshotMinimumCapacity ? maxCapacity : VDTPIDSnapshotMinimumCapacity;
    }

    for (unsigned attempt = 0; attempt < VDTPIDSnapshotReadLimit; ++attempt) {
        // Check before multiplying or narrowing to libproc's int argument.
        if (capacity == 0 || capacity > maxCapacity || capacity > SIZE_MAX / sizeof(int) ||
            capacity > (size_t)INT_MAX / sizeof(int)) {
            snapshot.error = E2BIG;
            return snapshot;
        }
        size_t capacityBytes = capacity * sizeof(int);
        int *buffer = (int *)operations->allocate(capacityBytes, operations->context);
        if (!buffer) {
            snapshot.error = ENOMEM;
            return snapshot;
        }
        // Even a misbehaving reader cannot expose uninitialised PID slots.
        memset(buffer, 0, capacityBytes);
        scanError = 0;
        int writtenBytes = operations->listPIDs(buffer, (int)capacityBytes, &scanError, operations->context);
        if (writtenBytes < 0 || scanError != 0) {
            operations->deallocate(buffer, operations->context);
            snapshot.error = scanError > 0 ? scanError : EIO;
            return snapshot;
        }
        if ((size_t)writtenBytes % sizeof(int) != 0 ||
            (size_t)writtenBytes > capacityBytes) {
            operations->deallocate(buffer, operations->context);
            snapshot.error = EINVAL;
            return snapshot;
        }
        if ((size_t)writtenBytes < capacityBytes) {
            snapshot.count = (size_t)writtenBytes / sizeof(int);
            snapshot.complete = true;
            if (snapshot.count != 0) snapshot.pids = buffer;
            else operations->deallocate(buffer, operations->context);
            return snapshot;
        }

        // A full buffer is not evidence of completeness. Discard it rather
        // than returning a prefix that a caller might mistake for absence.
        operations->deallocate(buffer, operations->context);
        if (capacity == maxCapacity) {
            snapshot.error = E2BIG;
            return snapshot;
        }
        capacity = capacity > maxCapacity / 2 ? maxCapacity : capacity * 2;
    }

    snapshot.error = EAGAIN;
    return snapshot;
}

#ifdef __cplusplus
}
#endif

#endif
