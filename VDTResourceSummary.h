// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#ifndef VDTResourceSummary_h
#define VDTResourceSummary_h
#include <stdbool.h>
#include <stdint.h>

// Counts cover the identified instances checked in ONE batch, never every
// process on the device. This kernel does not turn a scope qualifier into an
// execution failure and never promotes malformed/missing evidence to success.
typedef struct {
    uint32_t total;
    uint32_t applied;
    uint32_t restored;
    uint32_t failed;
    uint32_t pending;
    uint32_t unknown;
    uint32_t disabled;
} VDTResourceSummaryCounts;

typedef enum {
    VDTResourceSummaryNoResult = 0,
    VDTResourceSummaryConfirmed,
    VDTResourceSummaryRestored,
    VDTResourceSummaryPartial,
    VDTResourceSummaryFailed,
    VDTResourceSummaryPending,
    VDTResourceSummaryUnknown,
    VDTResourceSummaryDisabled,
    VDTResourceSummaryInvalid
} VDTResourceSummaryState;

static inline bool VDTResourceSummaryCountsValid(VDTResourceSummaryCounts value) {
    uint64_t sum = (uint64_t)value.applied + value.restored + value.failed +
        value.pending + value.unknown + value.disabled;
    return value.total <= 65536u && sum == value.total;
}
static inline uint32_t VDTResourceSummaryConfirmedCount(VDTResourceSummaryCounts value) {
    return VDTResourceSummaryCountsValid(value) ? value.applied + value.restored : 0;
}
static inline VDTResourceSummaryState VDTResourceSummaryDecide(VDTResourceSummaryCounts value) {
    if (!VDTResourceSummaryCountsValid(value)) return VDTResourceSummaryInvalid;
    if (!value.total) return VDTResourceSummaryNoResult;
    uint32_t confirmed = VDTResourceSummaryConfirmedCount(value);
    if (confirmed == value.total)
        return value.restored == value.total ? VDTResourceSummaryRestored : VDTResourceSummaryConfirmed;
    if (confirmed) return VDTResourceSummaryPartial;
    if (value.failed) return VDTResourceSummaryFailed;
    if (value.unknown) return VDTResourceSummaryUnknown;
    if (value.pending) return VDTResourceSummaryPending;
    return value.disabled == value.total ? VDTResourceSummaryDisabled : VDTResourceSummaryUnknown;
}

// Absence from a scan is deliberately NOT an input. Only explicit, validated
// current intent (or an authorized global off/removal) may revoke our override.
typedef enum {
    VDTResourceIntentUnknown = 0,
    VDTResourceIntentKeep,
    VDTResourceIntentRevoke
} VDTResourceCurrentIntent;
typedef struct {
    bool memory;
    bool priority;
} VDTResourceRestoreSelection;
static inline VDTResourceRestoreSelection VDTResourceSelectRestores(
    bool authorizedGlobalRevocation, bool ownsMemory, bool ownsPriority,
    VDTResourceCurrentIntent memory, VDTResourceCurrentIntent priority) {
    VDTResourceRestoreSelection result;
    result.memory = ownsMemory && (authorizedGlobalRevocation || memory == VDTResourceIntentRevoke);
    result.priority = ownsPriority && (authorizedGlobalRevocation || priority == VDTResourceIntentRevoke);
    return result;
}
#endif
