// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef VDTResourceApply_h
#define VDTResourceApply_h

// Apply engine: turns frozen-core policy intents into an ordered operation
// program and executes it through an injected backend, with capability gates,
// before/after identity checks, per-resource outcomes, partial-failure
// reporting and write-back restore records. No syscall and no dynamic memory
// live in this layer. See M5_PLAN.md for the full design and the evidence log.

#include "VDTMemoryPolicy.h"
#include "VDTJetsamPolicy.h"
#include "VDTResourceBackend.h"

#ifdef __cplusplus
extern "C" {
#endif

#define VDT_RESOURCE_APPLY_ABI_VERSION 1

// Verified mechanism constants. Evidence: m3-unlimited/REPORT.md (2026-10-13).
// Unlimited = the platform's own no-limit representation measured on the
// target device: SET pair INT32_MAX/INT32_MAX with attrs 0 (nonfatal), enforced
// limit ~2.2518 PB, read-back INT32_MAX/0; frida-core `without_limits()` uses
// the same values. The user ruling allows evidence-backed use; unproven
// big-number/raw -1/nonfatal substitutes remain forbidden.
#define VDT_APPLY_UNLIMITED_LIMIT INT32_MAX
#define VDT_APPLY_UNLIMITED_ATTRS 0
// First-version custom memory semantics are an explicit hard limit
// (MEMORY_PLAN §一). A nonfatal high-water mode would be a separate future mode
// and must not be mixed into Custom.
#define VDT_APPLY_CUSTOM_ATTRS 1

typedef struct {
    bool writeMemoryCustom;    // M2 device evidence
    bool writeMemoryUnlimited; // M3 device evidence + user ruling
    bool writeJetsamBand;      // M4 device evidence
    bool restoreWriteback;     // M2/M3/M4 write-back restores (non-CAS)
} VDTApplyCapabilities;

typedef enum {
    VDTApplySkipNone = 0,
    VDTApplySkipNoWrite,        // System/missing rule: intentionally nothing to do
    VDTApplySkipReadOnly,       // unknown target OS
    VDTApplySkipUnsupported,    // core refused (mixed pair, raw mismatch, reserved band, ...)
    VDTApplySkipCapabilityMissing,
    VDTApplySkipRestorePending, // no recorded prior value (or restore capability missing)
    VDTApplySkipIdentity,       // identity missing/mismatched: fail closed
    VDTApplySkipReadbackFailed, // pre-write read failed: fail closed
    VDTApplySkipBackendMissing  // backend lacks a required function
} VDTApplySkip;

typedef enum {
    VDTOpKindNone = 0,
    VDTOpKindSetPriority,
    VDTOpKindRestorePriority,
    VDTOpKindSetMemory,
    VDTOpKindRestoreMemory
} VDTOpKind;

typedef struct {
    VDTOpKind kind;
    int32_t priorityBand; // VDTOpKindSetPriority
    VDTMemlimitPair pair; // VDTOpKindSetMemory, fully resolved (attrs included)
} VDTApplyOp;

// At most one priority op and one memory op per program.
#define VDT_APPLY_MAX_OPS 2

typedef struct {
    pid_t pid;
    unsigned opCount;
    VDTApplyOp ops[VDT_APPLY_MAX_OPS]; // canonical order: priority side first
    VDTApplySkip memorySkip;
    VDTApplySkip jetsamSkip;
} VDTApplyProgram;

typedef struct {
    pid_t pid;
    bool hasExpectedToken;
    VDTProcessInstanceToken expected;
    bool hasPriorPair;      // recorded pre-management read-back pair
    VDTMemlimitPair priorPair;
    bool hasPriorPriority;  // recorded pre-management effective priority
    int32_t priorPriority;
} VDTApplyTarget;

typedef enum {
    VDTApplyOutcomeNone = 0,
    VDTApplyOutcomeApplied,
    VDTApplyOutcomeAppliedUnverified,
    VDTApplyOutcomeFailed,
    VDTApplyOutcomeSkipped,
    VDTApplyOutcomeRestored,
    VDTApplyOutcomeRestoreUnconfirmed
} VDTApplyOutcome;

typedef struct {
    bool hasValue;
    VDTMemlimitPair pair;
} VDTMemlimitSnapshot;
typedef struct {
    bool hasValue;
    int32_t priority;
} VDTPrioritySnapshot;

typedef struct {
    pid_t pid;
    bool identityPreChecked;
    bool identityPreMatched;
    bool identityPostChecked;
    bool identityPostMatched;
    VDTMemlimitSnapshot priorMemlimit; // captured before the memory write
    VDTPrioritySnapshot priorPriority; // captured before the priority write
    VDTApplyOutcome memoryOutcome;
    VDTApplyOutcome jetsamOutcome;
    bool memoryVerified;
    bool jetsamVerified;
    VDTMemlimitSnapshot afterMemlimit;
    VDTPrioritySnapshot afterPriority;
    bool partial; // one side applied while the other failed/skipped-with-intent
    VDTApplySkip memorySkip;
    VDTApplySkip jetsamSkip;
} VDTApplyReport;

// Builds the canonical program. `memoryRule`/`jetsamRule` are the rules the
// selection layer already resolved for this target; NULL means "not requested".
VDTApplyProgram VDTApplyBuildProgram(pid_t pid,
    const VDTMemoryRule *memoryRule,
    const VDTJetsamRule *jetsamRule,
    int32_t targetDarwinMajor,
    bool memoryPriorOverride,
    bool jetsamPriorOverride,
    VDTApplyCapabilities capabilities);

bool VDTApplyProgramHasMemory(const VDTApplyProgram *program);
bool VDTApplyProgramHasPriority(const VDTApplyProgram *program);

// Executes the program. Writes only when the instance token matches; records
// before/after observations for the manager's restore path (non-CAS: a
// read-back mismatch is reported, never silently corrected).
VDTApplyReport VDTApplyExecute(const VDTApplyProgram *program,
    const VDTApplyTarget *target,
    const VDTResourceBackend *backend,
    void *backendContext);

#ifdef __cplusplus
}
#endif
#endif
