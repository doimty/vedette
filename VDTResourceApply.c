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

// Identity results aggregate every operation. A successful token read is not
// a kernel-atomic binding; the caller latches any failure and never resumes.
static bool identityBefore(VDTApplyReport *report, const VDTApplyTarget *target,
    const VDTResourceBackend *backend, void *backendContext) {
    VDTProcessInstanceToken token = {0, 0};
    const bool readable = backend->getInstanceToken &&
        backend->getInstanceToken(backendContext, report->pid, &token);
    const bool matched = readable && report->pid > 0 && target &&
        target->pid == report->pid && target->hasExpectedToken &&
        VDTProcessInstanceMatches(target->expected, token);
    report->identityPreMatched = matched &&
        (!report->identityPreChecked || report->identityPreMatched);
    report->identityPreChecked = true;
    if (!matched) report->identityPostMatched = false;
    return matched;
}

static bool identityAfter(VDTApplyReport *report, const VDTApplyTarget *target,
    const VDTResourceBackend *backend, void *backendContext) {
    VDTProcessInstanceToken after = {0, 0};
    const bool readable = backend->getInstanceToken &&
        backend->getInstanceToken(backendContext, report->pid, &after);
    const bool matched = readable && target && target->hasExpectedToken &&
        VDTProcessInstanceMatches(target->expected, after);
    report->identityPostMatched = matched && report->identityPreMatched &&
        (!report->identityPostChecked || report->identityPostMatched);
    report->identityPostChecked = true;
    return matched;
}

VDTApplyReport VDTApplyExecute(const VDTApplyProgram *program,
    const VDTApplyTarget *target,
    const VDTResourceBackend *backend,
    void *backendContext) {
    VDTApplyReport report = {0};
    report.pid = program->pid;
    report.memorySkip = program->memorySkip;
    report.jetsamSkip = program->jetsamSkip;
    // Preserve the first original even when identity/backend/compare fails.
    // Fresh current observations below never replace an existing original.
    if (target && target->hasPriorPair) {
        report.priorMemlimit.hasValue = true;
        report.priorMemlimit.pair = target->priorPair;
    }
    if (target && target->hasPriorPriority) {
        report.priorPriority.hasValue = true;
        report.priorPriority.priority = target->priorPriority;
    }
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

    bool identityLost = false;

    for (unsigned i = 0; i < program->opCount; ++i) {
        const VDTApplyOp *op = &program->ops[i];
        if (op->kind == VDTOpKindSetPriority || op->kind == VDTOpKindRestorePriority) {
            const bool restore = op->kind == VDTOpKindRestorePriority;
            if (identityLost || !identityBefore(&report, target, backend, backendContext)) {
                identityLost = true;
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipIdentity;
                continue;
            }
            if (!backend->getPriority || !backend->setPriority) {
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipBackendMissing;
                continue;
            }
            if (restore && (!target->hasPriorPriority || !target->hasLastPriority)) {
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipRestorePending;
                continue;
            }
            const int32_t expected = restore ? target->priorPriority : op->priorityBand;
            VDTJetsamObservation before = {0};
            const bool readPriorityBefore = backend->getPriority(backendContext, program->pid, &before);
            // Also checks identity after a failed GET; its out value is ignored.
            // This token is the immediate pre-SET gate when the GET succeeded.
            if (!identityBefore(&report, target, backend, backendContext)) {
                identityLost = true;
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipIdentity;
                continue;
            }
            if (!readPriorityBefore) {
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipReadbackFailed;
                continue;
            }
            report.beforePriority.hasValue = true;
            report.beforePriority.priority = before.effectivePriority;
            if (!report.priorPriority.hasValue) {
                report.priorPriority = report.beforePriority;
            }
            if (target->hasLastPriority && before.effectivePriority != target->lastPriority) {
                report.jetsamOutcome = VDTApplyOutcomeSkipped;
                report.jetsamSkip = VDTApplySkipConflict;
                continue;
            }
            const bool wrotePriority = backend->setPriority(backendContext, program->pid, expected);
            report.jetsamOutcome = !wrotePriority ? VDTApplyOutcomeFailed :
                (restore ? VDTApplyOutcomeRestoreUnconfirmed : VDTApplyOutcomeAppliedUnverified);
            // Even a failed SET can race PID replacement: never let it authorize
            // the other resource. A successful SET stays observable immediately.
            if (!identityAfter(&report, target, backend, backendContext)) {
                identityLost = true;
                report.jetsamSkip = VDTApplySkipIdentity;
                continue;
            }
            if (!wrotePriority) continue;
            VDTJetsamObservation after = {0};
            const bool readPriorityAfter = backend->getPriority(backendContext, program->pid, &after);
            if (!identityAfter(&report, target, backend, backendContext)) {
                identityLost = true;
                report.jetsamSkip = VDTApplySkipIdentity;
                continue;
            }
            if (readPriorityAfter) {
                report.afterPriority.hasValue = true;
                report.afterPriority.priority = after.effectivePriority;
                // GET is effective, SET is requested: no invented coercion match.
                report.jetsamVerified = after.effectivePriority == expected;
            } else {
                report.jetsamSkip = VDTApplySkipReadbackFailed;
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
            if (identityLost || !identityBefore(&report, target, backend, backendContext)) {
                identityLost = true;
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipIdentity;
                continue;
            }
            if (!backend->getMemlimit || !backend->setMemlimit) {
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipBackendMissing;
                continue;
            }
            if (restore && (!target->hasPriorPair || !target->hasLastPair)) {
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipRestorePending;
                continue;
            }
            const VDTMemlimitPair expected = restore ? target->priorPair : op->pair;
            VDTMemlimitPair before = {0, 0, 0, 0};
            const bool readPairBefore = backend->getMemlimit(backendContext, program->pid, &before);
            if (!identityBefore(&report, target, backend, backendContext)) {
                identityLost = true;
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipIdentity;
                continue;
            }
            if (!readPairBefore) {
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipReadbackFailed;
                continue;
            }
            report.beforeMemlimit.hasValue = true;
            report.beforeMemlimit.pair = before;
            if (!report.priorMemlimit.hasValue) {
                report.priorMemlimit = report.beforeMemlimit;
            }
            if (target->hasLastPair && !pairEquals(before, target->lastPair)) {
                report.memoryOutcome = VDTApplyOutcomeSkipped;
                report.memorySkip = VDTApplySkipConflict;
                continue;
            }
            const bool wrotePair = backend->setMemlimit(backendContext, program->pid, &expected);
            report.memoryOutcome = !wrotePair ? VDTApplyOutcomeFailed :
                (restore ? VDTApplyOutcomeRestoreUnconfirmed : VDTApplyOutcomeAppliedUnverified);
            if (!identityAfter(&report, target, backend, backendContext)) {
                identityLost = true;
                report.memorySkip = VDTApplySkipIdentity;
                continue;
            }
            if (!wrotePair) continue;
            VDTMemlimitPair after = {0, 0, 0, 0};
            const bool readPairAfter = backend->getMemlimit(backendContext, program->pid, &after);
            if (!identityAfter(&report, target, backend, backendContext)) {
                identityLost = true;
                report.memorySkip = VDTApplySkipIdentity;
                continue;
            }
            if (readPairAfter) {
                report.afterMemlimit.hasValue = true;
                report.afterMemlimit.pair = after;
                report.memoryVerified = pairEquals(after, expected);
            } else {
                report.memorySkip = VDTApplySkipReadbackFailed;
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

    // A later operation can discover drift after an earlier verified write.
    // Keep the write evidence, but do not claim this batch stayed on-instance.
    if (identityLost) {
        report.identityPostMatched = false;
        if (report.memoryOutcome == VDTApplyOutcomeApplied ||
            report.memoryOutcome == VDTApplyOutcomeAppliedUnverified) {
            report.memoryOutcome = VDTApplyOutcomeAppliedUnverified;
            report.memoryVerified = false;
            report.memorySkip = VDTApplySkipIdentity;
        } else if (report.memoryOutcome == VDTApplyOutcomeRestored ||
            report.memoryOutcome == VDTApplyOutcomeRestoreUnconfirmed) {
            report.memoryOutcome = VDTApplyOutcomeRestoreUnconfirmed;
            report.memoryVerified = false;
            report.memorySkip = VDTApplySkipIdentity;
        }
        if (report.jetsamOutcome == VDTApplyOutcomeApplied ||
            report.jetsamOutcome == VDTApplyOutcomeAppliedUnverified) {
            report.jetsamOutcome = VDTApplyOutcomeAppliedUnverified;
            report.jetsamVerified = false;
            report.jetsamSkip = VDTApplySkipIdentity;
        } else if (report.jetsamOutcome == VDTApplyOutcomeRestored ||
            report.jetsamOutcome == VDTApplyOutcomeRestoreUnconfirmed) {
            report.jetsamOutcome = VDTApplyOutcomeRestoreUnconfirmed;
            report.jetsamVerified = false;
            report.jetsamSkip = VDTApplySkipIdentity;
        }
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
