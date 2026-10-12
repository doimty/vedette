// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "fake_resource_backend.h"

#include <stdio.h>
#include <string.h>

static FakeBackend *stateOf(void *context) {
    return (FakeBackend *)context;
}

static void appendLog(FakeBackend *state, const char *text) {
    if (state->logCount >= FAKE_LOG_CAPACITY) return;
    snprintf(state->log[state->logCount], FAKE_LOG_WIDTH, "%s", text);
    state->logCount++;
}

static FakeProcess *findProcess(FakeBackend *state, pid_t pid) {
    for (unsigned i = 0; i < FAKE_PROC_CAPACITY; ++i) {
        if (state->processes[i].pid == pid && state->processes[i].live) {
            return &state->processes[i];
        }
    }
    return NULL;
}

// Coercions measured on the target device (m4-jetsam/REPORT.md):
// -1 -> 18 (default shorthand), -2 -> idle head, aging bands 1/2 -> idle.
static int32_t coerceBand(const FakeBackend *state, int32_t band) {
    if (!state->modelAgingPolicyBands) return band;
    if (band == -1) return 18;
    if (band == -2 || band == 1 || band == 2) return 0;
    return band;
}

// Models the kernel cache selection for non-dirty-tracked processes: the
// enforced limit follows the active bucket at >= FOREGROUND(10). Re-evaluated
// on both priority and memory writes, matching the M4 linkage experiment.
static void recomputeEnforced(FakeProcess *p) {
    if (!p->hasPair || !p->hasPriority) {
        p->enforcedLimit = 0;
        return;
    }
    if (p->effectivePriority >= 10) {
        p->enforcedLimit = p->pair.active;
        p->enforceInactive = false;
    } else {
        p->enforcedLimit = p->pair.inactive;
        p->enforceInactive = true;
    }
}

static void maybeChangeToken(FakeProcess *p) {
    if (p->changeTokenAfterWrite) {
        p->token.seconds += 1;
        p->token.microseconds += 1;
    }
}

static bool fakeGetMemlimit(void *context, pid_t pid, VDTMemlimitPair *out) {
    FakeBackend *state = stateOf(context);
    char text[FAKE_LOG_WIDTH];
    snprintf(text, sizeof text, "getMem(%d)", (int)pid);
    appendLog(state, text);
    FakeProcess *p = findProcess(state, pid);
    if (!p || p->failGetPair || !p->hasPair) return false;
    *out = p->pair;
    return true;
}

static bool fakeSetMemlimit(void *context, pid_t pid, const VDTMemlimitPair *pair) {
    FakeBackend *state = stateOf(context);
    char text[FAKE_LOG_WIDTH];
    snprintf(text, sizeof text, "setMem(%d,%d/%d)", (int)pid, pair->active, pair->inactive);
    appendLog(state, text);
    FakeProcess *p = findProcess(state, pid);
    if (!p || p->failSetPair) return false;
    p->pair = *pair;
    p->hasPair = true;
    recomputeEnforced(p);
    maybeChangeToken(p);
    return true;
}

static bool fakeGetPriority(void *context, pid_t pid, VDTJetsamObservation *out) {
    FakeBackend *state = stateOf(context);
    char text[FAKE_LOG_WIDTH];
    snprintf(text, sizeof text, "getPrio(%d)", (int)pid);
    appendLog(state, text);
    FakeProcess *p = findProcess(state, pid);
    if (!p || p->failGetPriority || !p->hasPriority) return false;
    out->effectivePriority = p->effectivePriority;
    return true;
}

static bool fakeSetPriority(void *context, pid_t pid, int32_t band) {
    FakeBackend *state = stateOf(context);
    char text[FAKE_LOG_WIDTH];
    snprintf(text, sizeof text, "setPrio(%d,%d)", (int)pid, band);
    appendLog(state, text);
    FakeProcess *p = findProcess(state, pid);
    if (!p || p->failSetPriority) return false;
    p->effectivePriority = coerceBand(state, band);
    p->hasPriority = true;
    recomputeEnforced(p);
    maybeChangeToken(p);
    return true;
}

static bool fakeGetInstanceToken(void *context, pid_t pid, VDTProcessInstanceToken *out) {
    FakeBackend *state = stateOf(context);
    char text[FAKE_LOG_WIDTH];
    snprintf(text, sizeof text, "token(%d)", (int)pid);
    appendLog(state, text);
    FakeProcess *p = findProcess(state, pid);
    if (!p || p->failToken || !p->hasToken) return false;
    *out = p->token;
    return true;
}

static const VDTResourceBackend gFakeVtable = {
    "fake",
    fakeGetMemlimit,
    fakeSetMemlimit,
    fakeGetPriority,
    fakeSetPriority,
    fakeGetInstanceToken
};

const VDTResourceBackend *FakeBackendVtable(void) {
    return &gFakeVtable;
}

void FakeBackendReset(FakeBackend *state) {
    FakeBackend zero = {0};
    *state = zero;
}

FakeProcess *FakeBackendFind(FakeBackend *state, pid_t pid) {
    return findProcess(state, pid);
}

FakeProcess *FakeBackendAdd(FakeBackend *state, pid_t pid) {
    for (unsigned i = 0; i < FAKE_PROC_CAPACITY; ++i) {
        FakeProcess *p = &state->processes[i];
        if (p->pid != 0) continue;
        FakeProcess fresh = {0};
        *p = fresh;
        p->pid = pid;
        p->live = true;
        p->hasToken = true;
        p->token.seconds = (uint64_t)pid;
        p->token.microseconds = 1;
        return p;
    }
    return NULL;
}

unsigned FakeBackendLogIndex(const FakeBackend *state, const char *needle) {
    for (unsigned i = 0; i < state->logCount; ++i) {
        if (strstr(state->log[i], needle) != NULL) return i;
    }
    return (unsigned)-1;
}
