// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#include "VDTResourceSystemIO.h"
#include "VDTJetsamPolicy.h"
#include <errno.h>
#include <limits.h>
typedef struct { int32_t pid, priority; uint64_t userData; int32_t limit; uint32_t state; } ResourcePriority;
typedef struct { int32_t priority; uint32_t reserved; uint64_t userData; } ResourcePrioritySet;
_Static_assert(sizeof(VDTMemlimitPair) == 16, "memory ABI");
_Static_assert(offsetof(VDTMemlimitPair, inactive) == 8, "memory field order");
_Static_assert(sizeof(ResourcePriority) == 24 && offsetof(ResourcePriority, userData) == 8, "priority GET ABI");
_Static_assert(sizeof(ResourcePrioritySet) == 16 && offsetof(ResourcePrioritySet, userData) == 8, "priority SET ABI");
// No device/model/build/kernel-string whitelist. Access is decided by the
// native adapter and actual syscall result; only numeric band semantics vary.
static bool priorityMaximum(VDTResourceSystemIO *io, int32_t *maximum) {
    if (!io || !VDTJetsamMaxBand(io->darwinMajor, maximum)) { errno = EINVAL; return false; }
    return true;
}
static bool gate(VDTResourceSystemIO *io, pid_t pid) {
    if (!io || !io->control || !io->supported || !io->identity || !io->token ||
        pid <= 1 || pid == io->ownerPid) { errno = EINVAL; return false; }
    if (!io->supported(io->opaque)) { errno = ENOTSUP; return false; }
    if (!io->identity(io->opaque, pid)) { errno = ESTALE; return false; }
    return true;
}
static bool token(void *context, pid_t pid, VDTProcessInstanceToken *out) {
    VDTResourceSystemIO *io = context; VDTProcessInstanceToken value = {0};
    if (!out || !gate(io, pid)) return false;
    if (!io->token(io->opaque, pid, &value) || !VDTProcessInstanceTokenIsValid(value) || !gate(io, pid)) return false;
    *out = value; return true;
}
static bool pairValid(const VDTMemlimitPair *p) {
    return p && p->active > 0 && p->inactive > 0 && (p->activeAttrs == 0 || p->activeAttrs == 1) &&
        (p->inactiveAttrs == 0 || p->inactiveAttrs == 1);
}
static bool getMemory(void *context, pid_t pid, VDTMemlimitPair *out) {
    VDTResourceSystemIO *io = context; VDTMemlimitPair value = {0};
    if (!out || !gate(io, pid)) return false;
    if (io->control(8, pid, 0, &value, sizeof(value)) != 0) return false;
    if (!gate(io, pid)) return false;
    if (!pairValid(&value)) { errno = EPROTO; return false; }
    *out = value; return true;
}
static bool setMemory(void *context, pid_t pid, const VDTMemlimitPair *pair) {
    VDTResourceSystemIO *io = context;
    if (!pairValid(pair)) { errno = EINVAL; return false; }
    if (!gate(io, pid)) return false;
    VDTMemlimitPair copy = *pair;
    // Ret==0 reports that the write happened. A later identity failure is
    // reported by the execution engine's post-SET check, not disguised here.
    return io->control(7, pid, 0, &copy, sizeof(copy)) == 0;
}
static bool priorityRead(VDTResourceSystemIO *io, pid_t pid, ResourcePriority *out) {
    ResourcePriority value = {0}; int32_t maximum = 0;
    if (!gate(io, pid) || !priorityMaximum(io, &maximum)) return false;
    int length = io->control(1, pid, 0, &value, sizeof(value));
    if (length < 0) return false;
    if (!gate(io, pid)) return false;
    // Single-PID form is verified as exactly one 24-byte entry. Fail closed on
    // partial/bigger/wrong-PID payloads; no uninitialised allocation tail.
    if (length != sizeof(value) || value.pid != pid || value.priority < 0 || value.priority > maximum || value.userData != 0) {
        errno = EPROTO; return false;
    }
    *out = value; return true;
}
static bool getPriority(void *context, pid_t pid, VDTJetsamObservation *out) {
    ResourcePriority value;
    if (!out || !priorityRead(context, pid, &value)) return false;
    *out = (VDTJetsamObservation){value.priority}; return true;
}
static bool setPriority(void *context, pid_t pid, int32_t band) {
    VDTResourceSystemIO *io = context; ResourcePriority current; int32_t maximum = 0;
    if (!priorityMaximum(io, &maximum)) return false;
    if (band < -1 || band > maximum) { errno = EINVAL; return false; }
    // Never erase nonzero user_data, which the current restore model cannot
    // preserve. Effective priority is not requested/assertion policy state.
    if (!priorityRead(io, pid, &current) || !gate(io, pid)) return false;
    ResourcePrioritySet value = {band, 0, 0};
    return io->control(2, pid, 0, &value, sizeof(value)) == 0;
}
const VDTResourceBackend *VDTResourceKernelBackend(void) {
    static const VDTResourceBackend backend = {"fixed-memorystatus", getMemory, setMemory, getPriority, setPriority, token};
    return &backend;
}
