// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTResourceApply.h"

// ---------------------------------------------------------------------------
// Operation helpers
// ---------------------------------------------------------------------------

static VDTApplyOp priorityOperation(VDTOpKind kind, int32_t band) {
    VDTApplyOp op = {VDTOpKindNone, 0, {0, 0, 0, 0}};
    op.kind = kind;
    op.priorityBand = band;
    return op;
}

static VDTApplyOp memoryOperation(VDTOpKind kind, VDTMemlimitPair pair) {
    VDTApplyOp op = {VDTOpKindNone, 0, {0, 0, 0, 0}};
    op.kind = kind;
    op.pair = pair;
    return op;
}

static VDTMemlimitPair customPair(int32_t activeMiB, int32_t inactiveMiB) {
    VDTMemlimitPair pair = {activeMiB, VDT_APPLY_CUSTOM_ATTRS, inactiveMiB, VDT_APPLY_CUSTOM_ATTRS};
    return pair;
}

// INT32_MAX + attrs 0 is the device-verified unlimited representation (M3);
// the two scalar constants below are pinned by behavioral mutants.
static VDTMemlimitPair unlimitedPair(void) {
    const int32_t limit = VDT_APPLY_UNLIMITED_LIMIT;
    const int32_t attrs = VDT_APPLY_UNLIMITED_ATTRS;
    VDTMemlimitPair pair = {limit, attrs, limit, attrs};
    return pair;
}

static bool pairEquals(VDTMemlimitPair a, VDTMemlimitPair b) {
    return a.active == b.active && a.activeAttrs == b.activeAttrs &&
        a.inactive == b.inactive && a.inactiveAttrs == b.inactiveAttrs;
}

static bool programWantsMemory(const VDTApplyProgram *p) {
    for (unsigned i = 0; i < p->opCount; ++i) {
        if (p->ops[i].kind == VDTOpKindSetMemory ||
            p->ops[i].kind == VDTOpKindRestoreMemory) return true;
    }
    return false;
}

static bool programWantsPriority(const VDTApplyProgram *p) {
    for (unsigned i = 0; i < p->opCount; ++i) {
        if (p->ops[i].kind == VDTOpKindSetPriority ||
            p->ops[i].kind == VDTOpKindRestorePriority) return true;
    }
    return false;
}

bool VDTApplyProgramHasMemory(const VDTApplyProgram *program) {
    return program && programWantsMemory(program);
}

bool VDTApplyProgramHasPriority(const VDTApplyProgram *program) {
    return program && programWantsPriority(program);
}

// ---------------------------------------------------------------------------
// Intent planning: maps frozen-core plans to operations, never widening them
// ---------------------------------------------------------------------------

static void planMemory(const VDTMemoryRule *rule, int32_t targetDarwinMajor, bool priorOverride,
    VDTApplyCapabilities capabilities, bool *hasOp, VDTApplyOp *opValue, VDTApplySkip *skip) {
    if (!rule) {
        *skip = VDTApplySkipNone;
        return;
    }
    VDTMemoryPlan plan = VDTPlanMemoryRule(rule, targetDarwinMajor, priorOverride);
    switch (plan.status) {
        case VDTPolicyPlanReady:
            if (!capabilities.writeMemoryCustom) {
                *skip = VDTApplySkipCapabilityMissing;
                return;
            }
            *hasOp = true;
            *opValue = memoryOperation(VDTOpKindSetMemory, customPair(plan.activeMiB, plan.inactiveMiB));
            return;
        case VDTPolicyPlanNoWrite:
            *skip = VDTApplySkipNoWrite;
            return;
        case VDTPolicyPlanReadOnly:
            *skip = VDTApplySkipReadOnly;
            return;
        case VDTPolicyPlanRestoreRequired:
            if (!capabilities.restoreWriteback) {
                *skip = VDTApplySkipCapabilityMissing;
                return;
            }
            *hasOp = true;
            *opValue = memoryOperation(VDTOpKindRestoreMemory, (VDTMemlimitPair){0, 0, 0, 0});
            return;
        case VDTPolicyPlanUnsupported:
            if (plan.reason == VDTPolicyReasonUnlimitedUnverified &&
                rule->active.mode == VDTMemoryModeUnlimited &&
                rule->inactive.mode == VDTMemoryModeUnlimited) {
                if (!capabilities.writeMemoryUnlimited) {
                    *skip = VDTApplySkipCapabilityMissing;
                    return;
                }
                *hasOp = true;
                *opValue = memoryOperation(VDTOpKindSetMemory, unlimitedPair());
                return;
            }
            *skip = VDTApplySkipUnsupported;
            return;
        default:
            *skip = VDTApplySkipUnsupported;
            return;
    }
}

static void planJetsam(const VDTJetsamRule *rule, int32_t targetDarwinMajor, bool priorOverride,
    VDTApplyCapabilities capabilities, bool *hasOp, VDTApplyOp *opValue, VDTApplySkip *skip) {
    if (!rule) {
        *skip = VDTApplySkipNone;
        return;
    }
    VDTJetsamPlan plan = VDTPlanJetsamRule(rule, targetDarwinMajor, priorOverride);
    switch (plan.status) {
        case VDTPolicyPlanReady:
            if (!capabilities.writeJetsamBand) {
                *skip = VDTApplySkipCapabilityMissing;
                return;
            }
            *hasOp = true;
            *opValue = priorityOperation(VDTOpKindSetPriority, plan.band);
            return;
        case VDTPolicyPlanNoWrite:
            *skip = VDTApplySkipNoWrite;
            return;
        case VDTPolicyPlanReadOnly:
            *skip = VDTApplySkipReadOnly;
            return;
        case VDTPolicyPlanRestoreRequired:
            if (!capabilities.restoreWriteback) {
                *skip = VDTApplySkipCapabilityMissing;
                return;
            }
            *hasOp = true;
            *opValue = priorityOperation(VDTOpKindRestorePriority, 0);
            return;
        default:
            *skip = VDTApplySkipUnsupported;
            return;
    }
}

VDTApplyProgram VDTApplyBuildProgram(pid_t pid,
    const VDTMemoryRule *memoryRule,
    const VDTJetsamRule *jetsamRule,
    int32_t targetDarwinMajor,
    bool memoryPriorOverride,
    bool jetsamPriorOverride,
    VDTApplyCapabilities capabilities) {
    VDTApplyProgram program = {0};
    program.pid = pid;
    program.memorySkip = VDTApplySkipNone;
    program.jetsamSkip = VDTApplySkipNone;

    bool hasPriority = false;
    bool hasMemory = false;
    VDTApplyOp priorityValue = {VDTOpKindNone, 0, {0, 0, 0, 0}};
    VDTApplyOp memoryValue = {VDTOpKindNone, 0, {0, 0, 0, 0}};

    planJetsam(jetsamRule, targetDarwinMajor, jetsamPriorOverride, capabilities,
        &hasPriority, &priorityValue, &program.jetsamSkip);
    planMemory(memoryRule, targetDarwinMajor, memoryPriorOverride, capabilities,
        &hasMemory, &memoryValue, &program.memorySkip);

    unsigned count = 0;
    if (hasPriority) program.ops[count++] = priorityValue;
    if (hasMemory) program.ops[count++] = memoryValue;
    program.opCount = count;
    return program;
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

VDTApplyReport VDTApplyExecute(const VDTApplyProgram *program,
    const VDTApplyTarget *target,
    const VDTResourceBackend *backend,
    void *backendContext) {
    VDTApplyReport report = {0};
    report.pid = program->pid;
    report.memorySkip = program->memorySkip;
    report.jetsamSkip = program->jetsamSkip;
    if (program->opCount == 0) {
        return report;
    }

    const bool wantsMemory = programWantsMemory(program);
    const bool wantsPriority = programWantsPriority(program);

    if (!backend) {
        if (wantsMemory) {
            report.memoryOutcome = VDTApplyOutcomeSkipped;
            report.memorySkip = VDTApplySkipBackendMissing;
        }
        if (wantsPriority) {
            report.jetsamOutcome = VDTApplyOutcomeSkipped;
            report.jetsamSkip = VDTApplySkipBackendMissing;
        }
        return report;
    }

    // Fail-closed identity pre-check: no writes without a verified instance.
    VDTProcessInstanceToken token = {0, 0};
    const bool readable = backend->getInstanceToken &&
        backend->getInstanceToken(backendContext, program->pid, &token);
    const bool matched = readable && target && target->hasExpectedToken &&
        VDTProcessInstanceMatches(target->expected, token);
    report.identityPreChecked = true;
    report.identityPreMatched = matched;
    if (!matched) {
        if (wantsMemory) {
            report.memoryOutcome = VDTApplyOutcomeSkipped;
            report.memorySkip = VDTApplySkipIdentity;
        }
        if (wantsPriority) {
            report.jetsamOutcome = VDTApplyOutcomeSkipped;
            report.jetsamSkip = VDTApplySkipIdentity;
        }
        return report;
    }

    for (unsigned i = 0; i < program->opCount; ++i) {
        const VDTApplyOp *op = &program->ops[i];
        if (op->kind == VDTOpKindSetPriority || op->kind == VDTOpKindRestorePriority) {
            const bool restore = op->kind == VDTOpKindRestorePriority;
            if (!backend->getPriority || !backend->setPriority) {
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipBackendMissing;
                continue;
            }
            if (restore && (!target || !target->hasPriorPriority)) {
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipRestorePending;
                continue;
            }
            const int32_t expected = restore ? target->priorPriority : op->priorityBand;
            if (!restore) {
                VDTJetsamObservation before = {0};
                if (!backend->getPriority(backendContext, program->pid, &before)) {
                    report.jetsamOutcome = VDTApplyOutcomeSkipped;
                    report.jetsamSkip = VDTApplySkipReadbackFailed;
                    continue;
                }
                report.priorPriority.hasValue = true;
                report.priorPriority.priority = before.effectivePriority;
            }
            if (!backend->setPriority(backendContext, program->pid, expected)) {
                report.jetsamOutcome = VDTApplyOutcomeFailed;
                continue;
            }
            VDTJetsamObservation after = {0};
            if (backend->getPriority(backendContext, program->pid, &after)) {
                report.afterPriority.hasValue = true;
                report.afterPriority.priority = after.effectivePriority;
                report.jetsamVerified = after.effectivePriority == expected;
            } else {
                report.jetsamVerified = false;
            }
            if (restore) {
                report.jetsamOutcome = report.jetsamVerified
                    ? VDTApplyOutcomeRestored : VDTApplyOutcomeRestoreUnconfirmed;
            } else {
                report.jetsamOutcome = report.jetsamVerified
                    ? VDTApplyOutcomeApplied : VDTApplyOutcomeAppliedUnverified;
            }
            continue;
        }
        if (op->kind == VDTOpKindSetMemory || op->kind == VDTOpKindRestoreMemory) {
            const bool restore = op->kind == VDTOpKindRestoreMemory;
            if (!backend->getMemlimit || !backend->setMemlimit) {
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipBackendMissing;
                continue;
            }
            if (restore && (!target || !target->hasPriorPair)) {
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipRestorePending;
                continue;
            }
            const VDTMemlimitPair expected = restore ? target->priorPair : op->pair;
            if (!restore) {
                VDTMemlimitPair before = {0, 0, 0, 0};
                if (!backend->getMemlimit(backendContext, program->pid, &before)) {
                    report.memoryOutcome = VDTApplyOutcomeSkipped;
                    report.memorySkip = VDTApplySkipReadbackFailed;
                    continue;
                }
                report.priorMemlimit.hasValue = true;
                report.priorMemlimit.pair = before;
            }
            if (!backend->setMemlimit(backendContext, program->pid, &expected)) {
                report.memoryOutcome = VDTApplyOutcomeFailed;
                continue;
            }
            VDTMemlimitPair after = {0, 0, 0, 0};
            if (backend->getMemlimit(backendContext, program->pid, &after)) {
                report.afterMemlimit.hasValue = true;
                report.afterMemlimit.pair = after;
                report.memoryVerified = pairEquals(after, expected);
            } else {
                report.memoryVerified = false;
            }
            if (restore) {
                report.memoryOutcome = report.memoryVerified
                    ? VDTApplyOutcomeRestored : VDTApplyOutcomeRestoreUnconfirmed;
            } else {
                report.memoryOutcome = report.memoryVerified
                    ? VDTApplyOutcomeApplied : VDTApplyOutcomeAppliedUnverified;
            }
            continue;
        }
    }

    // Post-write instance re-check: records drift after the writes happened.
    if (backend->getInstanceToken) {
        VDTProcessInstanceToken after = {0, 0};
        const bool readableAfter = backend->getInstanceToken(backendContext, program->pid, &after);
        report.identityPostChecked = true;
        report.identityPostMatched = readableAfter && target && target->hasExpectedToken &&
            VDTProcessInstanceMatches(target->expected, after);
    }

    const bool memoryGood = report.memoryOutcome == VDTApplyOutcomeApplied ||
        report.memoryOutcome == VDTApplyOutcomeAppliedUnverified ||
        report.memoryOutcome == VDTApplyOutcomeRestored ||
        report.memoryOutcome == VDTApplyOutcomeRestoreUnconfirmed;
    const bool priorityGood = report.jetsamOutcome == VDTApplyOutcomeApplied ||
        report.jetsamOutcome == VDTApplyOutcomeAppliedUnverified ||
        report.jetsamOutcome == VDTApplyOutcomeRestored ||
        report.jetsamOutcome == VDTApplyOutcomeRestoreUnconfirmed;
    const bool memoryProblem = report.memoryOutcome == VDTApplyOutcomeFailed ||
        (report.memoryOutcome == VDTApplyOutcomeSkipped && report.memorySkip != VDTApplySkipNoWrite);
    const bool priorityProblem = report.jetsamOutcome == VDTApplyOutcomeFailed ||
        (report.jetsamOutcome == VDTApplyOutcomeSkipped && report.jetsamSkip != VDTApplySkipNoWrite);
    report.partial = wantsMemory && wantsPriority &&
        ((memoryGood && priorityProblem) || (priorityGood && memoryProblem));
    return report;
}
