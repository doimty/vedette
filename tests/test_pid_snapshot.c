// Executes the exact production header kernel with fake listpids/allocators.
// No libproc, Foundation, process metadata, syscall or device participates.
#include "VDTPIDSnapshot.h"
// These behavioral tests must execute assertions even in optimized Zig builds.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

// Negative sentinel replies are fake controls, not values returned to the kernel.
enum { FakeFull = -2, FakeOverCapacity = -3, FakeMaximumReads = 16 };
typedef struct {
    int bytes;
    int error;
    bool shortWrite;
} FakeReply;
typedef struct {
    int queryBytes;
    int queryError;
    FakeReply replies[FakeMaximumReads];
    bool alwaysFull;
    unsigned queryCalls;
    unsigned readCalls;
    unsigned allocationCalls;
    unsigned freeCalls;
    unsigned liveBuffers;
    unsigned failAllocation;
    size_t capacities[FakeMaximumReads];
} FakeList;

static void *fake_allocate(size_t bytes, void *context) {
    FakeList *fake = (FakeList *)context;
    ++fake->allocationCalls;
    assert(fake->liveBuffers == 0); // Growth releases the previous buffer first.
    assert(bytes > 0 && bytes % sizeof(int) == 0);
    assert(bytes <= (size_t)VDTPIDSnapshotMaxPIDs * sizeof(int));
    assert(bytes <= (size_t)INT_MAX);
    if (fake->allocationCalls == fake->failAllocation) return NULL;
    void *buffer = malloc(bytes);
    assert(buffer != NULL);
    memset(buffer, 0x7f, bytes); // The kernel, not malloc, must initialise storage.
    ++fake->liveBuffers;
    return buffer;
}

static void fake_deallocate(void *buffer, void *context) {
    FakeList *fake = (FakeList *)context;
    assert(buffer != NULL && fake->liveBuffers == 1);
    --fake->liveBuffers;
    ++fake->freeCalls;
    free(buffer);
}

static int fake_listpids(int *buffer, int capacityBytes, int *outError, void *context) {
    FakeList *fake = (FakeList *)context;
    assert(outError != NULL && *outError == 0); // Never inherit a previous errno.
    if (!buffer) {
        assert(capacityBytes == 0 && fake->queryCalls == 0);
        ++fake->queryCalls;
        *outError = fake->queryError;
        return fake->queryBytes;
    }

    assert(fake->liveBuffers == 1);
    assert(capacityBytes > 0 && (size_t)capacityBytes % sizeof(int) == 0);
    assert(fake->readCalls < FakeMaximumReads);
    unsigned read = fake->readCalls++;
    fake->capacities[read] = (size_t)capacityBytes / sizeof(int);
    for (size_t i = 0; i < fake->capacities[read]; ++i) assert(buffer[i] == 0);

    FakeReply reply = fake->replies[read];
    int bytes = fake->alwaysFull || reply.bytes == FakeFull ? capacityBytes : reply.bytes;
    if (reply.bytes == FakeOverCapacity) bytes = capacityBytes + (int)sizeof(int);
    size_t writes = bytes > 0 ? (size_t)bytes / sizeof(int) : 0;
    if (writes > fake->capacities[read]) writes = fake->capacities[read];
    if (reply.shortWrite && writes > 1) writes = 1;
    for (size_t i = 0; i < writes; ++i) buffer[i] = 100 + (int)i;
    *outError = reply.error;
    return bytes;
}

static VDTPIDSnapshot scan(FakeList *fake) {
    VDTPIDSnapshotOperations operations = {fake_listpids, fake_allocate, fake_deallocate, fake};
    return VDTCopyPIDSnapshot(&operations);
}

static void expect_failure(VDTPIDSnapshot snapshot, FakeList *fake, int error) {
    assert(!snapshot.complete && snapshot.error == error);
    assert(snapshot.pids == NULL && snapshot.count == 0);
    assert(fake->liveBuffers == 0);
    assert(fake->freeCalls + (fake->failAllocation != 0 ? 1u : 0u) == fake->allocationCalls);
}

static void release_success(VDTPIDSnapshot snapshot, FakeList *fake, size_t count) {
    assert(snapshot.complete && snapshot.error == 0 && snapshot.count == count);
    if (count == 0) {
        assert(snapshot.pids == NULL && fake->liveBuffers == 0);
    } else {
        assert(snapshot.pids != NULL && fake->liveBuffers == 1);
        for (size_t i = 0; i < count; ++i) assert(snapshot.pids[i] == 100 + (int)i);
        fake_deallocate(snapshot.pids, fake);
    }
    assert(fake->freeCalls == fake->allocationCalls && fake->liveBuffers == 0);
}

static void test_empty_and_byte_count(void) {
    FakeList empty = {0};
    release_success(scan(&empty), &empty, 0);
    assert(empty.queryCalls == 1 && empty.readCalls == 1);
    assert(empty.capacities[0] == VDTPIDSnapshotMinimumCapacity);

    FakeList disappeared = {0};
    disappeared.queryBytes = 3 * (int)sizeof(int);
    release_success(scan(&disappeared), &disappeared, 0);
    assert(disappeared.readCalls == 1);

    FakeList ordinary = {0};
    ordinary.queryBytes = 3 * (int)sizeof(int);
    ordinary.replies[0].bytes = 3 * (int)sizeof(int);
    release_success(scan(&ordinary), &ordinary, 3); // Three elements, not 12.
    assert(ordinary.readCalls == 1 && ordinary.capacities[0] > 3);

    FakeList appeared = {0}; // An empty estimate is not an empty PID read.
    appeared.replies[0].bytes = 2 * (int)sizeof(int);
    release_success(scan(&appeared), &appeared, 2);
    assert(appeared.readCalls == 1);

    FakeList headroom = {0};
    headroom.queryBytes = 256 * (int)sizeof(int);
    headroom.replies[0].bytes = headroom.queryBytes;
    release_success(scan(&headroom), &headroom, 256);
    assert(headroom.readCalls == 1 && headroom.capacities[0] == 320);
}

static void test_failed_query_and_read(void) {
    int queryBytes[] = {0, -1, -1};
    int queryErrors[] = {EPERM, EACCES, 0};
    int expectedQueryErrors[] = {EPERM, EACCES, EIO};
    for (unsigned i = 0; i < 3; ++i) {
        FakeList fake = {0};
        fake.queryBytes = queryBytes[i];
        fake.queryError = queryErrors[i];
        expect_failure(scan(&fake), &fake, expectedQueryErrors[i]);
        assert(fake.queryCalls == 1 && fake.readCalls == 0 && fake.allocationCalls == 0);
    }

    int readBytes[] = {0, -1, -1};
    int readErrors[] = {EACCES, EINTR, 0};
    int expectedReadErrors[] = {EACCES, EINTR, EIO};
    for (unsigned i = 0; i < 3; ++i) {
        FakeList fake = {0};
        fake.queryBytes = 5 * (int)sizeof(int);
        fake.replies[0].bytes = readBytes[i];
        fake.replies[0].error = readErrors[i];
        expect_failure(scan(&fake), &fake, expectedReadErrors[i]);
        assert(fake.readCalls == 1 && fake.freeCalls == 1); // No syscall retries.
    }

    FakeList failedAfterGrowth = {0};
    failedAfterGrowth.queryBytes = (int)sizeof(int);
    failedAfterGrowth.replies[0].bytes = FakeFull;
    failedAfterGrowth.replies[1].error = EPERM;
    expect_failure(scan(&failedAfterGrowth), &failedAfterGrowth, EPERM);
    assert(failedAfterGrowth.readCalls == 2 && failedAfterGrowth.freeCalls == 2);
}

static void test_growth_and_bounds(void) {
    FakeList transient = {0};
    transient.queryBytes = 4 * (int)sizeof(int);
    transient.replies[0].bytes = FakeFull;
    transient.replies[1].bytes = (VDTPIDSnapshotMinimumCapacity + 4) * (int)sizeof(int);
    release_success(scan(&transient), &transient, VDTPIDSnapshotMinimumCapacity + 4);
    assert(transient.readCalls == 2 && transient.freeCalls == 2);
    assert(transient.capacities[0] == 128 && transient.capacities[1] == 256);

    FakeList truncation = {0};
    truncation.queryBytes = (int)sizeof(int);
    truncation.alwaysFull = true;
    expect_failure(scan(&truncation), &truncation, EAGAIN);
    assert(VDTPIDSnapshotReadLimit == 6 && truncation.readCalls == 6);
    assert(truncation.freeCalls == 6);
    for (unsigned i = 0; i < truncation.readCalls; ++i) {
        assert(truncation.capacities[i] == ((size_t)128 << i));
    }

    FakeList lastAllowedRead = {0};
    lastAllowedRead.queryBytes = (int)sizeof(int);
    for (unsigned i = 0; i < 5; ++i) lastAllowedRead.replies[i].bytes = FakeFull;
    lastAllowedRead.replies[5].bytes = (4096 - 1) * (int)sizeof(int);
    release_success(scan(&lastAllowedRead), &lastAllowedRead, 4096 - 1);
    assert(lastAllowedRead.readCalls == 6 && lastAllowedRead.capacities[5] == 4096);

    FakeList ceiling = {0};
    ceiling.queryBytes = VDTPIDSnapshotMaxPIDs * (int)sizeof(int);
    ceiling.alwaysFull = true;
    expect_failure(scan(&ceiling), &ceiling, E2BIG);
    assert(ceiling.readCalls == 1 && ceiling.capacities[0] == VDTPIDSnapshotMaxPIDs);

    FakeList nearCeiling = {0};
    nearCeiling.queryBytes = (VDTPIDSnapshotMaxPIDs / 2) * (int)sizeof(int);
    nearCeiling.replies[0].bytes = FakeFull;
    nearCeiling.replies[1].bytes = (VDTPIDSnapshotMaxPIDs - 1) * (int)sizeof(int);
    release_success(scan(&nearCeiling), &nearCeiling, VDTPIDSnapshotMaxPIDs - 1);
    assert(nearCeiling.readCalls == 2 && nearCeiling.capacities[1] == VDTPIDSnapshotMaxPIDs);
}

static void test_malformed_and_oversized_bytes(void) {
    assert(sizeof(int) > 1); // The production PID ABI and portable hosts use int slots.
    FakeList queryMisaligned = {0};
    queryMisaligned.queryBytes = (int)sizeof(int) + 1;
    expect_failure(scan(&queryMisaligned), &queryMisaligned, EINVAL);
    assert(queryMisaligned.allocationCalls == 0 && queryMisaligned.readCalls == 0);

    int oversized[] = {(VDTPIDSnapshotMaxPIDs + 1) * (int)sizeof(int),
                       INT_MAX - INT_MAX % (int)sizeof(int)};
    for (unsigned i = 0; i < 2; ++i) {
        FakeList fake = {0};
        fake.queryBytes = oversized[i];
        expect_failure(scan(&fake), &fake, E2BIG);
        assert(fake.allocationCalls == 0 && fake.readCalls == 0);
    }

    int malformedReads[] = {(int)sizeof(int) + 1, FakeOverCapacity,
                            INT_MAX - INT_MAX % (int)sizeof(int)};
    for (unsigned i = 0; i < 3; ++i) {
        FakeList fake = {0};
        fake.queryBytes = (int)sizeof(int);
        fake.replies[0].bytes = malformedReads[i];
        expect_failure(scan(&fake), &fake, EINVAL);
        assert(fake.readCalls == 1 && fake.freeCalls == 1);
    }

    FakeList malformedAfterGrowth = {0};
    malformedAfterGrowth.replies[0].bytes = FakeFull;
    malformedAfterGrowth.replies[1].bytes = 1;
    expect_failure(scan(&malformedAfterGrowth), &malformedAfterGrowth, EINVAL);
    assert(malformedAfterGrowth.readCalls == 2 && malformedAfterGrowth.freeCalls == 2);
}

static void test_allocation_failure_and_initialisation(void) {
    FakeList first = {0};
    first.queryBytes = (int)sizeof(int);
    first.failAllocation = 1;
    expect_failure(scan(&first), &first, ENOMEM);
    assert(first.allocationCalls == 1 && first.readCalls == 0 && first.freeCalls == 0);

    FakeList growth = {0};
    growth.queryBytes = (int)sizeof(int);
    growth.replies[0].bytes = FakeFull;
    growth.failAllocation = 2;
    expect_failure(scan(&growth), &growth, ENOMEM);
    assert(growth.allocationCalls == 2 && growth.readCalls == 1 && growth.freeCalls == 1);

    FakeList shortWrite = {0};
    shortWrite.queryBytes = 8 * (int)sizeof(int);
    shortWrite.replies[0].bytes = shortWrite.queryBytes;
    shortWrite.replies[0].shortWrite = true;
    VDTPIDSnapshot snapshot = scan(&shortWrite);
    assert(snapshot.complete && snapshot.error == 0 && snapshot.count == 8);
    assert(snapshot.pids != NULL && snapshot.pids[0] == 100);
    for (size_t i = 1; i < snapshot.count; ++i) assert(snapshot.pids[i] == 0);
    fake_deallocate(snapshot.pids, &shortWrite);
    assert(shortWrite.liveBuffers == 0 && shortWrite.freeCalls == 1);

    FakeList invalid = {0};
    VDTPIDSnapshotOperations operations = {NULL, fake_allocate, fake_deallocate, &invalid};
    expect_failure(VDTCopyPIDSnapshot(NULL), &invalid, EINVAL);
    expect_failure(VDTCopyPIDSnapshot(&operations), &invalid, EINVAL);
    operations.listPIDs = fake_listpids;
    operations.allocate = NULL;
    expect_failure(VDTCopyPIDSnapshot(&operations), &invalid, EINVAL);
    operations.allocate = fake_allocate;
    operations.deallocate = NULL;
    expect_failure(VDTCopyPIDSnapshot(&operations), &invalid, EINVAL);
    assert(invalid.queryCalls == 0 && invalid.allocationCalls == 0);
}

int main(void) {
    test_empty_and_byte_count();
    test_failed_query_and_read();
    test_growth_and_bounds();
    test_malformed_and_oversized_bytes();
    test_allocation_failure_and_initialisation();
    puts("PASS production PID snapshot: empty vs failure, byte counts, headroom/growth, 6-read/65536-PID bounds, malformed sizes, allocation failures, no stale slots/leaks");
    return 0;
}
