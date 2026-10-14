// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef FAKE_RESOURCE_BACKEND_H
#define FAKE_RESOURCE_BACKEND_H

// Host-only fake backend for engine tests. It models the behaviors measured on
// the target device (M4: priority crossing FOREGROUND(10) switches which stored
// limit is enforced; aging bands 1/2 and -1/-2 are coerced) so engine ordering
// and reporting can be asserted without any device or syscall.

#include "VDTResourceBackend.h"

#define FAKE_LOG_CAPACITY 40
#define FAKE_LOG_WIDTH 48
#define FAKE_PROC_CAPACITY 4

typedef struct {
    pid_t pid;
    bool live;
    bool hasToken;
    VDTProcessInstanceToken token;
    bool hasPair;
    VDTMemlimitPair pair;
    bool hasPriority;
    int32_t effectivePriority;
    int32_t enforcedLimit; // models the currently enforced (cached) limit
    bool enforceInactive;
    bool failGetPair;
    bool failSetPair;
    bool failGetPriority;
    bool failSetPriority;
    bool failToken;
    bool changeTokenAfterWrite;
    unsigned getPairCalls;
    unsigned getPriorityCalls;
    unsigned failGetPairOnCall;     // 1-based, zero disables
    unsigned failGetPriorityOnCall;
} FakeProcess;

typedef enum {
    FakeCallbackFaultNone = 0,
    FakeCallbackReplaceInstance,
    FakeCallbackTokenUnavailable
} FakeCallbackFault;

typedef struct {
    FakeProcess processes[FAKE_PROC_CAPACITY];
    char log[FAKE_LOG_CAPACITY][FAKE_LOG_WIDTH];
    unsigned logCount;
    bool modelAgingPolicyBands;
    unsigned callbackCount;
    unsigned faultAfterCallback; // mutate identity after this callback returned its value
    FakeCallbackFault callbackFault;
    bool poisonFailedReads; // deliberately violate out-on-failure to test distrust
} FakeBackend;

const VDTResourceBackend *FakeBackendVtable(void);
void FakeBackendReset(FakeBackend *state);
FakeProcess *FakeBackendFind(FakeBackend *state, pid_t pid);
FakeProcess *FakeBackendAdd(FakeBackend *state, pid_t pid);
unsigned FakeBackendLogIndex(const FakeBackend *state, const char *needle);
unsigned FakeBackendLogCount(const FakeBackend *state, const char *needle);

#endif
