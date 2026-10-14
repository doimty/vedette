// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTResourceApply.h"
#include "fake_resource_backend.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>

_Static_assert(VDT_RESOURCE_APPLY_ABI_VERSION == 1, "apply ABI version");
_Static_assert(VDT_APPLY_MAX_OPS == 2, "op capacity");
_Static_assert(VDTApplySkipBackendMissing == 8, "old skip values stay stable");
_Static_assert(VDTApplySkipConflict == 9, "conflict appended");

static VDTPolicyInteger integer(int64_t value) {
    return (VDTPolicyInteger){VDTPolicyInputInteger, value};
}

static VDTMemoryRule memoryRule(VDTPolicyRecordState state, int64_t active, int64_t inactive) {
    VDTMemoryRuleInput input = {state, integer(1), integer(active), integer(inactive)};
    return VDTParseMemoryRule(&input);
}

static VDTJetsamRule namedRule(VDTPolicyRecordState state, VDTJetsamNamedBand band) {
    VDTJetsamRuleInput input = {0};
    input.state = state;
    input.schema = integer(1);
    input.mode = VDTJetsamModeNamed;
    input.named = band;
    return VDTParseJetsamRule(&input);
}

static VDTJetsamRule rawRule(VDTPolicyRecordState state, int64_t band, int64_t sourceMajor) {
    VDTJetsamRuleInput input = {0};
    input.state = state;
    input.schema = integer(1);
    input.mode = VDTJetsamModeRaw;
    input.rawBand = integer(band);
    input.rawSourceDarwinMajor = integer(sourceMajor);
    return VDTParseJetsamRule(&input);
}

static VDTApplyCapabilities capsOff(void) {
    VDTApplyCapabilities c = {0};
    return c;
}
static VDTApplyCapabilities capsCustom(void) {
    VDTApplyCapabilities c = {0};
    c.writeMemoryCustom = true;
    return c;
}
static VDTApplyCapabilities capsUnlimited(void) {
    VDTApplyCapabilities c = {0};
    c.writeMemoryUnlimited = true;
    return c;
}
static VDTApplyCapabilities capsRestore(void) {
    VDTApplyCapabilities c = {0};
    c.restoreWriteback = true;
    return c;
}
static VDTApplyCapabilities capsJetsam(void) {
    VDTApplyCapabilities c = {0};
    c.writeJetsamBand = true;
    return c;
}
static VDTApplyCapabilities capsFull(void) {
    VDTApplyCapabilities c = {0};
    c.writeMemoryCustom = true;
    c.writeMemoryUnlimited = true;
    c.writeJetsamBand = true;
    c.restoreWriteback = true;
    return c;
}

static FakeProcess *prepareProcess(FakeBackend *fake, pid_t pid, int32_t priority) {
    FakeProcess *p = FakeBackendAdd(fake, pid);
    assert(p != NULL);
    p->hasPair = true;
    p->pair = (VDTMemlimitPair){VDT_APPLY_UNLIMITED_LIMIT, 0, VDT_APPLY_UNLIMITED_LIMIT, 0};
    p->hasPriority = true;
    p->effectivePriority = priority;
    return p;
}

static VDTApplyTarget targetFor(FakeProcess *process) {
    VDTApplyTarget target = {0};
    target.pid = process->pid;
    target.hasExpectedToken = true;
    target.expected = process->token;
    return target;
}

static void test_constants(void) {
    assert(VDT_APPLY_UNLIMITED_LIMIT == INT32_MAX);
    assert(VDT_APPLY_UNLIMITED_ATTRS == 0);
    assert(VDT_APPLY_CUSTOM_ATTRS == 1);
    printf("[ok] verified constants\n");
}

static void test_capability_gate(void) {
    VDTApplyCapabilities off = capsOff();
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 128);
    VDTJetsamRule named = namedRule(VDTPolicyRecordEnabled, VDTJetsamNamedForeground);
    VDTApplyProgram program = VDTApplyBuildProgram(77, &custom, &named, 21, false, false, off);
    assert(program.opCount == 0);
    assert(program.memorySkip == VDTApplySkipCapabilityMissing);
    assert(program.jetsamSkip == VDTApplySkipCapabilityMissing);

    VDTMemoryRule unlimited = memoryRule(VDTPolicyRecordEnabled, -1, -1);
    VDTApplyProgram gated = VDTApplyBuildProgram(77, &unlimited, NULL, 21, false, false, off);
    assert(gated.opCount == 0);
    assert(gated.memorySkip == VDTApplySkipCapabilityMissing);
    printf("[ok] capability gate\n");
}

static void test_memory_custom_apply(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 900, 18);
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 128);
    VDTApplyProgram program = VDTApplyBuildProgram(900, &custom, NULL, 21, false, false, capsCustom());
    assert(program.opCount == 1);
    assert(program.ops[0].kind == VDTOpKindSetMemory);
    assert(program.ops[0].pair.active == 64 && program.ops[0].pair.activeAttrs == 1);
    assert(program.ops[0].pair.inactive == 128 && program.ops[0].pair.inactiveAttrs == 1);

    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeApplied);
    assert(report.memoryVerified);
    assert(report.jetsamOutcome == VDTApplyOutcomeNone);
    assert(report.priorMemlimit.hasValue);
    assert(report.priorMemlimit.pair.active == INT32_MAX);
    assert(report.afterMemlimit.hasValue);
    assert(report.afterMemlimit.pair.active == 64 && report.afterMemlimit.pair.inactive == 128);
    assert(report.identityPreMatched && report.identityPostChecked && report.identityPostMatched);
    assert(!report.partial);
    assert(p->pair.active == 64 && p->pair.activeAttrs == 1);
    assert(p->pair.inactive == 128 && p->pair.inactiveAttrs == 1);
    printf("[ok] memory custom apply\n");
}

static void test_memory_unlimited_apply(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 901, 18);
    VDTMemoryRule unlimited = memoryRule(VDTPolicyRecordEnabled, -1, -1);
    VDTApplyProgram program = VDTApplyBuildProgram(901, &unlimited, NULL, 21, false, false, capsUnlimited());
    assert(program.opCount == 1);
    assert(program.ops[0].pair.active == INT32_MAX && program.ops[0].pair.activeAttrs == 0);
    assert(program.ops[0].pair.inactive == INT32_MAX && program.ops[0].pair.inactiveAttrs == 0);

    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeApplied);
    assert(report.memoryVerified);
    printf("[ok] memory unlimited apply (INT32_MAX, attrs 0)\n");
}

static void test_mixed_pairs_stay_unsupported(void) {
    VDTApplyCapabilities full = capsFull();

    VDTMemoryRule mixedUnlimited = memoryRule(VDTPolicyRecordEnabled, -1, 64);
    VDTApplyProgram a = VDTApplyBuildProgram(78, &mixedUnlimited, NULL, 21, false, false, full);
    assert(a.opCount == 0);
    assert(a.memorySkip == VDTApplySkipUnsupported);

    VDTMemoryRule mixedSystem = memoryRule(VDTPolicyRecordEnabled, 0, 64);
    VDTApplyProgram b = VDTApplyBuildProgram(78, &mixedSystem, NULL, 21, false, false, full);
    assert(b.opCount == 0);
    assert(b.memorySkip == VDTApplySkipUnsupported);
    printf("[ok] mixed pairs stay unsupported\n");
}

static void test_restore_memory_writeback(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 902, 18);
    p->pair = (VDTMemlimitPair){64, 1, 128, 1};

    VDTMemoryRule disabled = memoryRule(VDTPolicyRecordDisabled, 0, 0);
    VDTApplyProgram program = VDTApplyBuildProgram(902, &disabled, NULL, 21, true, false, capsRestore());
    assert(program.opCount == 1);
    assert(program.ops[0].kind == VDTOpKindRestoreMemory);

    VDTApplyTarget target = targetFor(p);
    target.hasPriorPair = true;
    target.priorPair = (VDTMemlimitPair){1200, 0, 1050, 0};
    target.hasLastPair = true;
    target.lastPair = p->pair;
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeRestored);
    assert(report.memoryVerified);
    assert(report.afterMemlimit.pair.active == 1200);
    assert(report.afterMemlimit.pair.inactive == 1050);
    assert(p->pair.active == 1200 && p->pair.inactive == 1050);
    assert(FakeBackendLogIndex(&fake, "setMem(902,1200/1050)") != (unsigned)-1);
    printf("[ok] restore memory write-back exact pair\n");
}

static void test_restore_pending_and_gate(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 903, 18);

    VDTMemoryRule disabled = memoryRule(VDTPolicyRecordDisabled, 0, 0);
    VDTApplyProgram program = VDTApplyBuildProgram(903, &disabled, NULL, 21, true, false, capsRestore());
    assert(program.opCount == 1);

    VDTApplyTarget target = targetFor(p); // no recorded prior pair
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeSkipped);
    assert(report.memorySkip == VDTApplySkipRestorePending);
    assert(FakeBackendLogIndex(&fake, "setMem") == (unsigned)-1);

    VDTApplyProgram gated = VDTApplyBuildProgram(903, &disabled, NULL, 21, true, false, capsOff());
    assert(gated.opCount == 0);
    assert(gated.memorySkip == VDTApplySkipCapabilityMissing);
    printf("[ok] restore pending and capability gate\n");
}

static void test_identity_fail_closed(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 904, 18);
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 64);
    VDTApplyProgram program = VDTApplyBuildProgram(904, &custom, NULL, 21, false, false, capsCustom());

    VDTApplyTarget wrong = targetFor(p);
    wrong.expected = (VDTProcessInstanceToken){0xFFFF, 9};
    VDTApplyReport report = VDTApplyExecute(&program, &wrong, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeSkipped);
    assert(report.memorySkip == VDTApplySkipIdentity);
    assert(!report.identityPreMatched);
    assert(FakeBackendLogIndex(&fake, "setMem") == (unsigned)-1);
    assert(FakeBackendLogIndex(&fake, "getMem") == (unsigned)-1);

    VDTApplyTarget unverifiable = targetFor(p);
    unverifiable.hasExpectedToken = false;
    VDTApplyReport second = VDTApplyExecute(&program, &unverifiable, FakeBackendVtable(), &fake);
    assert(second.memoryOutcome == VDTApplyOutcomeSkipped);
    assert(second.memorySkip == VDTApplySkipIdentity);
    assert(FakeBackendLogIndex(&fake, "setMem") == (unsigned)-1);
    printf("[ok] identity fail-closed\n");
}

static void test_identity_post_check(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 905, 18);
    p->changeTokenAfterWrite = true;
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 64);
    VDTApplyProgram program = VDTApplyBuildProgram(905, &custom, NULL, 21, false, false, capsCustom());
    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeAppliedUnverified);
    assert(!report.memoryVerified && !report.afterMemlimit.hasValue);
    assert(report.memorySkip == VDTApplySkipIdentity);
    assert(report.identityPostChecked);
    assert(!report.identityPostMatched);
    printf("[ok] identity post-check records drift\n");
}

static void test_partial_failure_keeps_other_side(void) {
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 128);
    VDTJetsamRule named = namedRule(VDTPolicyRecordEnabled, VDTJetsamNamedForeground);

    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 906, 18);
    p->failSetPriority = true;
    VDTApplyProgram program = VDTApplyBuildProgram(906, &custom, &named, 21, false, false, capsFull());
    assert(program.opCount == 2);
    assert(program.ops[0].kind == VDTOpKindSetPriority);
    assert(program.ops[1].kind == VDTOpKindSetMemory);
    assert(program.ops[0].priorityBand == 10);

    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.jetsamOutcome == VDTApplyOutcomeFailed);
    assert(report.memoryOutcome == VDTApplyOutcomeApplied);
    assert(report.partial);
    unsigned prioAttempt = FakeBackendLogIndex(&fake, "setPrio(906,");
    unsigned memAttempt = FakeBackendLogIndex(&fake, "setMem(906,");
    assert(prioAttempt != (unsigned)-1 && memAttempt != (unsigned)-1);
    assert(prioAttempt < memAttempt);
    assert(p->pair.active == 64);

    FakeBackend fake2;
    FakeBackendReset(&fake2);
    FakeProcess *p2 = prepareProcess(&fake2, 907, 18);
    p2->failSetPair = true;
    VDTApplyProgram program2 = VDTApplyBuildProgram(907, &custom, &named, 21, false, false, capsFull());
    VDTApplyTarget target2 = targetFor(p2);
    VDTApplyReport report2 = VDTApplyExecute(&program2, &target2, FakeBackendVtable(), &fake2);
    assert(report2.memoryOutcome == VDTApplyOutcomeFailed);
    assert(report2.jetsamOutcome == VDTApplyOutcomeApplied);
    assert(report2.partial);
    assert(p2->effectivePriority == 10);
    assert(FakeBackendLogIndex(&fake2, "setPrio(907,10)") != (unsigned)-1);
    printf("[ok] partial failure keeps the other side\n");
}

static void test_order_and_linkage_model(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 908, 18);
    p->pair = (VDTMemlimitPair){64, 0, 128, 0};

    VDTApplyProgram program = {0};
    program.pid = 908;
    program.opCount = 2;
    program.ops[0].kind = VDTOpKindSetPriority;
    program.ops[0].priorityBand = 5;
    program.ops[1].kind = VDTOpKindSetMemory;
    program.ops[1].pair = (VDTMemlimitPair){200, 1, 300, 1};

    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.jetsamOutcome == VDTApplyOutcomeApplied);
    assert(report.memoryOutcome == VDTApplyOutcomeApplied);
    assert(p->effectivePriority == 5);
    assert(p->enforceInactive);
    assert(p->enforcedLimit == 300);
    unsigned prioIndex = FakeBackendLogIndex(&fake, "setPrio(908,5)");
    unsigned memIndex = FakeBackendLogIndex(&fake, "setMem(908,200/300)");
    assert(prioIndex != (unsigned)-1 && memIndex != (unsigned)-1 && prioIndex < memIndex);

    // Reversed order reaches the same final enforced value (M4 linkage).
    FakeBackend fake2;
    FakeBackendReset(&fake2);
    FakeProcess *p2 = prepareProcess(&fake2, 909, 18);
    p2->pair = (VDTMemlimitPair){64, 0, 128, 0};
    VDTApplyProgram reversed = {0};
    reversed.pid = 909;
    reversed.opCount = 2;
    reversed.ops[0].kind = VDTOpKindSetMemory;
    reversed.ops[0].pair = (VDTMemlimitPair){200, 1, 300, 1};
    reversed.ops[1].kind = VDTOpKindSetPriority;
    reversed.ops[1].priorityBand = 5;
    VDTApplyTarget target2 = targetFor(p2);
    VDTApplyReport report2 = VDTApplyExecute(&reversed, &target2, FakeBackendVtable(), &fake2);
    assert(report2.jetsamOutcome == VDTApplyOutcomeApplied);
    assert(report2.memoryOutcome == VDTApplyOutcomeApplied);
    assert(p2->enforcedLimit == 300);
    printf("[ok] order and linkage model\n");
}

static void test_coercion_surfaces_unverified(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    fake.modelAgingPolicyBands = true;
    FakeProcess *p = prepareProcess(&fake, 910, 18);
    VDTApplyProgram program = {0};
    program.pid = 910;
    program.opCount = 1;
    program.ops[0].kind = VDTOpKindSetPriority;
    program.ops[0].priorityBand = 1; // reserved aging band: kernel coerces to idle

    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.jetsamOutcome == VDTApplyOutcomeAppliedUnverified);
    assert(!report.jetsamVerified);
    assert(report.afterPriority.hasValue);
    assert(report.afterPriority.priority == 0);
    assert(!report.partial);
    printf("[ok] coercion surfaces applied-unverified\n");
}

static void test_skip_taxonomy(void) {
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 128);
    VDTApplyProgram unknownOS = VDTApplyBuildProgram(79, &custom, NULL, 20, false, false, capsFull());
    assert(unknownOS.opCount == 0 && unknownOS.memorySkip == VDTApplySkipReadOnly);

    const int32_t futureOS[] = {25, 26, 30, INT32_MAX};
    VDTJetsamRule named = namedRule(VDTPolicyRecordEnabled, VDTJetsamNamedForeground);
    for (size_t i = 0; i < sizeof(futureOS) / sizeof(futureOS[0]); ++i) {
        VDTApplyProgram future = VDTApplyBuildProgram(79, &custom, &named, futureOS[i], false, false, capsFull());
        assert(future.opCount == 2);
        assert(future.memorySkip == VDTApplySkipNone && future.jetsamSkip == VDTApplySkipNone);
        assert(future.ops[0].kind == VDTOpKindSetPriority && future.ops[0].priorityBand == 100);
        assert(future.ops[1].kind == VDTOpKindSetMemory);
        assert(future.ops[1].pair.active == 64 && future.ops[1].pair.activeAttrs == VDT_APPLY_CUSTOM_ATTRS);
        assert(future.ops[1].pair.inactive == 128 && future.ops[1].pair.inactiveAttrs == VDT_APPLY_CUSTOM_ATTRS);

        FakeBackend fake;
        FakeBackendReset(&fake);
        FakeProcess *p = prepareProcess(&fake, 79, 180);
        VDTApplyTarget target = targetFor(p);
        VDTApplyReport report = VDTApplyExecute(&future, &target, FakeBackendVtable(), &fake);
        assert(report.memoryOutcome == VDTApplyOutcomeApplied && report.memoryVerified);
        assert(report.jetsamOutcome == VDTApplyOutcomeApplied && report.jetsamVerified);
        assert(p->effectivePriority == 100 && p->pair.active == 64 && p->pair.inactive == 128);
    }

    VDTMemoryRule systemOnly = memoryRule(VDTPolicyRecordEnabled, 0, 0);
    VDTApplyProgram system = VDTApplyBuildProgram(79, &systemOnly, NULL, 21, false, false, capsFull());
    assert(system.opCount == 0 && system.memorySkip == VDTApplySkipNoWrite);

    VDTApplyProgram absent = VDTApplyBuildProgram(79, NULL, NULL, 21, false, false, capsFull());
    assert(absent.opCount == 0);
    assert(absent.memorySkip == VDTApplySkipNone && absent.jetsamSkip == VDTApplySkipNone);

    VDTJetsamRule rawMismatch = rawRule(VDTPolicyRecordEnabled, 10, 22);
    VDTApplyProgram raw = VDTApplyBuildProgram(79, NULL, &rawMismatch, 21, false, false, capsFull());
    assert(raw.opCount == 0 && raw.jetsamSkip == VDTApplySkipUnsupported);

    VDTJetsamRule reserved = namedRule(VDTPolicyRecordEnabled, VDTJetsamNamedIdleDeferred);
    VDTApplyProgram reservedProgram = VDTApplyBuildProgram(79, NULL, &reserved, 21, false, false, capsFull());
    assert(reservedProgram.opCount == 0 && reservedProgram.jetsamSkip == VDTApplySkipUnsupported);
    printf("[ok] skip taxonomy\n");
}

static void test_readback_failure_fail_closed(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 911, 18);
    p->failGetPair = true;
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 64);
    VDTApplyProgram program = VDTApplyBuildProgram(911, &custom, NULL, 21, false, false, capsCustom());
    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, FakeBackendVtable(), &fake);
    assert(report.memoryOutcome == VDTApplyOutcomeSkipped);
    assert(report.memorySkip == VDTApplySkipReadbackFailed);
    assert(FakeBackendLogIndex(&fake, "setMem") == (unsigned)-1);

    FakeBackend fake2;
    FakeBackendReset(&fake2);
    FakeProcess *p2 = prepareProcess(&fake2, 912, 18);
    p2->failGetPriority = true;
    VDTJetsamRule named = namedRule(VDTPolicyRecordEnabled, VDTJetsamNamedForeground);
    VDTApplyProgram program2 = VDTApplyBuildProgram(912, NULL, &named, 21, false, false, capsJetsam());
    VDTApplyTarget target2 = targetFor(p2);
    VDTApplyReport report2 = VDTApplyExecute(&program2, &target2, FakeBackendVtable(), &fake2);
    assert(report2.jetsamOutcome == VDTApplyOutcomeSkipped);
    assert(report2.jetsamSkip == VDTApplySkipReadbackFailed);
    assert(FakeBackendLogIndex(&fake2, "setPrio") == (unsigned)-1);
    printf("[ok] readback failure fails closed\n");
}

static void test_backend_missing(void) {
    FakeBackend fake;
    FakeBackendReset(&fake);
    FakeProcess *p = prepareProcess(&fake, 913, 18);
    VDTMemoryRule custom = memoryRule(VDTPolicyRecordEnabled, 64, 64);
    VDTApplyProgram program = VDTApplyBuildProgram(913, &custom, NULL, 21, false, false, capsCustom());
    VDTApplyTarget target = targetFor(p);
    VDTApplyReport report = VDTApplyExecute(&program, &target, NULL, NULL);
    assert(report.memoryOutcome == VDTApplyOutcomeSkipped);
    assert(report.memorySkip == VDTApplySkipBackendMissing);
    printf("[ok] missing backend fails closed\n");
}

static void test_conditional_restore_and_per_operation_identity(void) {
    FakeBackend f; FakeBackendReset(&f); FakeProcess *p = prepareProcess(&f, 914, 18);
    VDTMemoryRule m = memoryRule(VDTPolicyRecordEnabled,64,128);
    VDTJetsamRule j = namedRule(VDTPolicyRecordEnabled,VDTJetsamNamedForeground);
    VDTApplyTarget t=targetFor(p); t.hasPriorPair=true; t.priorPair=(VDTMemlimitPair){1024,0,2048,0};
    VDTMemoryRule off = memoryRule(VDTPolicyRecordDisabled,0,0);
    VDTJetsamRule offPriority = namedRule(VDTPolicyRecordDisabled,VDTJetsamNamedForeground);
    VDTApplyProgram restore=VDTApplyBuildProgram(914,&off,NULL,21,true,false,capsFull());
    VDTApplyReport r=VDTApplyExecute(&restore,&t,FakeBackendVtable(),&f);
    assert(r.memorySkip==VDTApplySkipRestorePending && FakeBackendLogCount(&f,"setMem")==0);
    t.hasLastPair=true; t.lastPair=(VDTMemlimitPair){64,1,128,1};
    r=VDTApplyExecute(&restore,&t,FakeBackendVtable(),&f);
    assert(r.memorySkip==VDTApplySkipConflict && FakeBackendLogCount(&f,"setMem")==0);
    assert(r.priorMemlimit.hasValue && r.priorMemlimit.pair.active==1024);
    VDTApplyProgram apply=VDTApplyBuildProgram(914,&m,NULL,21,true,false,capsFull());
    r=VDTApplyExecute(&apply,&t,FakeBackendVtable(),&f);
    assert(r.memorySkip==VDTApplySkipConflict && FakeBackendLogCount(&f,"setMem")==0);
    FakeBackendReset(&f); p=prepareProcess(&f,914,18); t=targetFor(p);
    apply=VDTApplyBuildProgram(914,&m,&j,21,false,false,capsFull());
    f.faultAfterCallback=2; f.callbackFault=FakeCallbackReplaceInstance; // GET -> pre-SET identity
    r=VDTApplyExecute(&apply,&t,FakeBackendVtable(),&f);
    assert(FakeBackendLogCount(&f,"setPrio")==0 && FakeBackendLogCount(&f,"setMem")==0);
    assert(r.jetsamSkip==VDTApplySkipIdentity && r.memorySkip==VDTApplySkipIdentity);
    FakeBackendReset(&f); p=prepareProcess(&f,914,18); t=targetFor(p);
    p->changeTokenAfterWrite=true;
    r=VDTApplyExecute(&apply,&t,FakeBackendVtable(),&f);
    assert(FakeBackendLogCount(&f,"setPrio")==1 && FakeBackendLogCount(&f,"setMem")==0);
    assert(r.jetsamOutcome==VDTApplyOutcomeAppliedUnverified && r.memorySkip==VDTApplySkipIdentity);
    FakeBackendReset(&f); p=prepareProcess(&f,914,18); t=targetFor(p);
    t.hasPriorPriority=true; t.priorPriority=13; t.hasLastPriority=true; t.lastPriority=18;
    restore=VDTApplyBuildProgram(914,NULL,&offPriority,21,false,true,capsFull());
    p->failGetPriorityOnCall=2;
    r=VDTApplyExecute(&restore,&t,FakeBackendVtable(),&f);
    assert(r.jetsamOutcome==VDTApplyOutcomeRestoreUnconfirmed && r.priorPriority.priority==13);
    assert(!r.afterPriority.hasValue && FakeBackendLogCount(&f,"setPrio")==1);
    puts("[ok] conditional writeback, kept originals, identity after GET/between resources, unconfirmed restore");
}

int main(void) {
    test_conditional_restore_and_per_operation_identity();
    test_constants();
    test_capability_gate();
    test_memory_custom_apply();
    test_memory_unlimited_apply();
    test_mixed_pairs_stay_unsupported();
    test_restore_memory_writeback();
    test_restore_pending_and_gate();
    test_identity_fail_closed();
    test_identity_post_check();
    test_partial_failure_keeps_other_side();
    test_order_and_linkage_model();
    test_coercion_surfaces_unverified();
    test_skip_taxonomy();
    test_readback_failure_fail_closed();
    test_backend_missing();
    printf("test_resource_apply: all scenarios passed\n");
    return 0;
}
