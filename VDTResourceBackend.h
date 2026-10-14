// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef VDTResourceBackend_h
#define VDTResourceBackend_h

// Injectable backend boundary for memory-limit and jetsam-priority operations.
//
// This header performs no syscall. Production wiring may only supply an
// implementation after the corresponding capability has been verified on the
// target system (see M5_PLAN.md §2); host tests must use the fake backend in
// tests/fake_resource_backend.c. The engine itself never writes directly.

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#include "VDTProcessIdentity.h"

#ifdef __cplusplus
extern "C" {
#endif

// Raw 16-byte `memorystatus_memlimit_properties_t` pair exactly as produced by
// GET_MEMLIMIT_PROPERTIES (command 8): active, active attrs, inactive, inactive
// attrs. Attribute values stay verbatim; the engine never invents a default for
// a field it did not observe (m1-blockers/REPORT.md).
typedef struct {
    int32_t active;
    int32_t activeAttrs;
    int32_t inactive;
    int32_t inactiveAttrs;
} VDTMemlimitPair;

// Effective jetsam priority as returned by GET_PRIORITY_LIST (command 1).
// GET exposes the effective value; requested/assertion state is not observable
// through this interface (m1-blockers/REPORT.md, m4-jetsam/REPORT.md).
typedef struct {
    int32_t effectivePriority;
} VDTJetsamObservation;

// Contract: every function returns false on failure; a reader should leave
// `out` untouched on failure, but callers MUST ignore it whenever false is
// returned. SET true means a write occurred, not that effective == requested.
// The engine fails closed on unavailable reads (never writes invented defaults).
// `band` is the resolved numeric value produced by the policy core; this layer
// performs no mapping or migration, including effective-priority coercions.
typedef struct VDTResourceBackend {
    const char *name;
    bool (*getMemlimit)(void *context, pid_t pid, VDTMemlimitPair *out);
    bool (*setMemlimit)(void *context, pid_t pid, const VDTMemlimitPair *pair);
    bool (*getPriority)(void *context, pid_t pid, VDTJetsamObservation *out);
    bool (*setPriority)(void *context, pid_t pid, int32_t band);
    // Instance token (seconds, microseconds) checked before every GET/SET and
    // after every SET/verification GET. These checks are not an atomic binding
    // to a syscall: a missing/mismatched token stops all subsequent writes.
    bool (*getInstanceToken)(void *context, pid_t pid, VDTProcessInstanceToken *out);
} VDTResourceBackend;

#ifdef __cplusplus
}
#endif
#endif
