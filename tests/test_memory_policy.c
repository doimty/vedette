// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTMemoryPolicy.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>

static VDTPolicyInteger integer(int64_t value) {
    return (VDTPolicyInteger){VDTPolicyInputInteger, value};
}
static VDTMemoryRule parse(VDTPolicyRecordState state, int64_t active, int64_t inactive) {
    VDTMemoryRuleInput in = {state, integer(1), integer(active), integer(inactive)};
    return VDTParseMemoryRule(&in);
}

// This recorder consumes only abstract intents; it has no syscall/backend hooks.
typedef struct { unsigned count; int32_t active; int32_t inactive; } FakeRecorder;
static void record(FakeRecorder *fake, VDTMemoryPlan plan) {
    if (plan.status != VDTPolicyPlanReady) {
        assert(!plan.hasCustomPair && plan.activeMiB == 0 && plan.inactiveMiB == 0);
        return;
    }
    assert(plan.hasCustomPair && plan.activeMiB > 0 && plan.inactiveMiB > 0);
    fake->count++;
    fake->active = plan.activeMiB;
    fake->inactive = plan.inactiveMiB;
}

static void test_typed_inputs(void) {
    const int64_t values[] = {-1, 0, 1, 256, INT32_MAX};
    const VDTMemoryMode modes[] = {VDTMemoryModeUnlimited, VDTMemoryModeSystem,
        VDTMemoryModeCustom, VDTMemoryModeCustom, VDTMemoryModeCustom};
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        VDTMemoryLimit limit = {VDTMemoryModeCustom, 123};
        assert(VDTParseMemoryLimit(integer(values[i]), &limit) == VDTPolicyParseOK);
        assert(limit.mode == modes[i]);
        assert(limit.mib == (values[i] > 0 ? values[i] : 0));
    }
    const int64_t bad[] = {INT64_MIN, INT32_MIN, -2, -100, (int64_t)INT32_MAX + 1, INT64_MAX};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        VDTMemoryLimit limit = {VDTMemoryModeCustom, 321};
        assert(VDTParseMemoryLimit(integer(bad[i]), &limit) == VDTPolicyParseOutOfRange);
        assert(limit.mode == VDTMemoryModeInvalid && limit.mib == 0);
    }
    const VDTPolicyInputTag tags[] = {VDTPolicyInputInvalid, VDTPolicyInputBoolean,
        VDTPolicyInputNull, VDTPolicyInputString, VDTPolicyInputFloatingPoint,
        VDTPolicyInputOverflow, (VDTPolicyInputTag)99};
    for (size_t i = 0; i < sizeof(tags) / sizeof(tags[0]); ++i) {
        for (int64_t value = 0; value <= 1; ++value) {
            VDTMemoryLimit limit = {VDTMemoryModeCustom, 8};
            assert(VDTParseMemoryLimit((VDTPolicyInteger){tags[i], value}, &limit) == VDTPolicyParseInvalidType);
            assert(limit.mode == VDTMemoryModeInvalid && limit.mib == 0);
        }
    }
    assert(VDTParseMemoryLimit(integer(32), NULL) == VDTPolicyParseInvalidArgument);
    assert(VDTPolicyReadInt32(integer(0), NULL) == VDTPolicyParseInvalidArgument);
    int32_t raw = 45;
    assert(VDTPolicyReadInt32(integer(INT32_MIN), &raw) == VDTPolicyParseOK && raw == INT32_MIN);
    assert(VDTPolicyReadInt32(integer(INT64_MAX), &raw) == VDTPolicyParseOutOfRange && raw == 0);
}

static void test_modes_and_plans(void) {
    const int64_t values[] = {0, -1, 128};
    const VDTMemoryMode modes[] = {VDTMemoryModeSystem, VDTMemoryModeUnlimited, VDTMemoryModeCustom};
    const int32_t versions[] = {21, 22, 23, 24, 25, 26, 30, INT32_MAX};
    const size_t versionCount = sizeof(versions) / sizeof(versions[0]);
    FakeRecorder fake = {0, 0, 0};
    // All 9 active/inactive combinations on legacy, modern and future majors.
    for (size_t v = 0; v < versionCount; ++v) {
        for (size_t a = 0; a < 3; ++a) for (size_t i = 0; i < 3; ++i) {
            VDTMemoryRule rule = parse(VDTPolicyRecordEnabled, values[a], values[i]);
            assert(rule.parseStatus == VDTPolicyParseOK && rule.state == VDTPolicyRecordEnabled);
            assert(rule.active.mode == modes[a] && rule.inactive.mode == modes[i]);
            for (unsigned prior = 0; prior < 2; ++prior) {
                VDTMemoryPlan plan = VDTPlanMemoryRule(&rule, versions[v], prior != 0);
                assert(plan.priorOverride == (prior != 0));
                if (a == 0 && i == 0) {
                    assert(plan.status == (prior ? VDTPolicyPlanRestoreRequired : VDTPolicyPlanNoWrite));
                    assert(plan.reason == (prior ? VDTPolicyReasonRestoreUnverified : VDTPolicyReasonNone));
                } else if (a == 1 || i == 1) {
                    assert(plan.status == VDTPolicyPlanUnsupported);
                    assert(plan.reason == VDTPolicyReasonUnlimitedUnverified);
                } else if (a == 0 || i == 0) {
                    assert(plan.status == VDTPolicyPlanUnsupported);
                    assert(plan.reason == VDTPolicyReasonMixedSystemUnverified);
                } else {
                    assert(plan.status == VDTPolicyPlanReady && plan.reason == VDTPolicyReasonNone);
                    assert(plan.activeMiB == 128 && plan.inactiveMiB == 128);
                }
                record(&fake, plan);
            }
        }
    }
    assert(fake.count == 2 * versionCount);
    VDTMemoryRule different = parse(VDTPolicyRecordEnabled, 333, 77);
    record(&fake, VDTPlanMemoryRule(&different, 21, false));
    assert(fake.count == 2 * versionCount + 1 && fake.active == 333 && fake.inactive == 77);
    VDTMemoryRule large = parse(VDTPolicyRecordEnabled, INT32_MAX, 1);
    VDTMemoryPlan largePlan = VDTPlanMemoryRule(&large, 22, false);
    assert(largePlan.status == VDTPolicyPlanReady && largePlan.activeMiB == INT32_MAX && largePlan.inactiveMiB == 1);
    // INT32_MAX is a user-specified Custom, NEVER an implementation of Unlimited.
    const int32_t unknown[] = {0, -1, 20};
    for (size_t v = 0; v < sizeof(unknown) / sizeof(unknown[0]); ++v) {
        VDTMemoryPlan plan = VDTPlanMemoryRule(&different, unknown[v], true);
        assert(plan.status == VDTPolicyPlanReadOnly && plan.reason == VDTPolicyReasonUnknownTargetOS);
        assert(plan.priorOverride);
        record(&fake, plan);
    }
}

static void test_records_and_transitions(void) {
    VDTMemoryRule missing = parse(VDTPolicyRecordMissing, -2, INT64_MAX);
    VDTMemoryRule disabled = parse(VDTPolicyRecordDisabled, -2, INT64_MAX);
    assert(missing.state == VDTPolicyRecordMissing && missing.parseStatus == VDTPolicyParseOK);
    assert(disabled.state == VDTPolicyRecordDisabled && disabled.parseStatus == VDTPolicyParseOK);
    const VDTMemoryRule records[] = {missing, disabled};
    FakeRecorder fake = {0, 0, 0};
    for (size_t i = 0; i < 2; ++i) {
        VDTMemoryPlan fresh = VDTPlanMemoryRule(&records[i], 21, false);
        VDTMemoryPlan old = VDTPlanMemoryRule(&records[i], 21, true);
        assert(fresh.status == VDTPolicyPlanNoWrite && !fresh.priorOverride);
        assert(old.status == VDTPolicyPlanRestoreRequired && old.priorOverride);
        record(&fake, fresh); record(&fake, old);
    }
    VDTMemoryRuleInput input = {VDTPolicyRecordEnabled, integer(1), integer(8), integer(16)};
    input.schema = integer(2);
    VDTMemoryRule bad = VDTParseMemoryRule(&input);
    assert(bad.state == VDTPolicyRecordInvalid && bad.parseStatus == VDTPolicyParseUnknownSchema);
    input.schema = (VDTPolicyInteger){VDTPolicyInputBoolean, 1};
    assert(VDTParseMemoryRule(&input).parseStatus == VDTPolicyParseInvalidType);
    input.schema = integer(1); input.active = integer(-2);
    bad = VDTParseMemoryRule(&input);
    assert(bad.state == VDTPolicyRecordInvalid && bad.active.mode == VDTMemoryModeInvalid);
    assert(bad.inactive.mode == VDTMemoryModeCustom && bad.inactive.mib == 16);
    VDTMemoryPlan invalid = VDTPlanMemoryRule(&bad, 21, true);
    assert(invalid.status == VDTPolicyPlanInvalid && invalid.priorOverride);
    record(&fake, invalid);
    input.active = integer(8); input.inactive = (VDTPolicyInteger){VDTPolicyInputNull, 0};
    bad = VDTParseMemoryRule(&input);
    assert(bad.state == VDTPolicyRecordInvalid && bad.active.mib == 8 && bad.inactive.mode == VDTMemoryModeInvalid);
    input.state = (VDTPolicyRecordState)98;
    assert(VDTParseMemoryRule(&input).parseStatus == VDTPolicyParseInvalidRecord);
    input.state = VDTPolicyRecordInvalid;
    assert(VDTParseMemoryRule(&input).parseStatus == VDTPolicyParseInvalidRecord);
    assert(VDTParseMemoryRule(NULL).parseStatus == VDTPolicyParseInvalidArgument);
    assert(VDTPlanMemoryRule(NULL, 21, true).status == VDTPolicyPlanInvalid);
    // Reject forged normalized policies rather than exposing sentinel payloads.
    bad = parse(VDTPolicyRecordEnabled, 0, 0); bad.active.mib = -1;
    assert(VDTPlanMemoryRule(&bad, 21, false).status == VDTPolicyPlanInvalid);
    bad = parse(VDTPolicyRecordEnabled, 8, 16); bad.active.mode = (VDTMemoryMode)99;
    assert(VDTPlanMemoryRule(&bad, 21, false).status == VDTPolicyPlanInvalid);
    bad = parse(VDTPolicyRecordEnabled, 8, 16); bad.inactive.mib = 0;
    assert(VDTPlanMemoryRule(&bad, 21, false).status == VDTPolicyPlanInvalid);
    assert(fake.count == 0);
    // Requested transitions never clear previous-instance evidence or pretend
    // local deletion/off/Unlimited proved an effective kernel restoration.
    VDTMemoryRule custom = parse(VDTPolicyRecordEnabled, 512, 256);
    VDTMemoryRule system = parse(VDTPolicyRecordEnabled, 0, 0);
    VDTMemoryRule unlimited = parse(VDTPolicyRecordEnabled, -1, -1);
    assert(VDTPlanMemoryRule(&custom, 22, true).status == VDTPolicyPlanReady);
    assert(VDTPlanMemoryRule(&system, 22, true).status == VDTPolicyPlanRestoreRequired);
    assert(VDTPlanMemoryRule(&unlimited, 22, true).status == VDTPolicyPlanUnsupported);
}

static void check_selection(bool identity, VDTPolicyRecordState app,
    VDTPolicyRecordState ext, VDTResourceRuleSelection actual) {
    VDTPolicyRuleOrigin origin = VDTPolicyOriginNone;
    VDTPolicyRecordState state = VDTPolicyRecordMissing;
    if (!identity) state = VDTPolicyRecordInvalid;
    else if (ext != VDTPolicyRecordMissing) { origin = VDTPolicyOriginExtension; state = ext; }
    else if (app != VDTPolicyRecordMissing) { origin = VDTPolicyOriginApp; state = app; }
    assert(actual.origin == origin && actual.state == state);
}

static void test_resource_inheritance(void) {
    // 4096 independent 3-resource state tuples, twice for identity eligibility.
    for (unsigned bits = 0; bits < 4096; ++bits) {
        VDTResourceRecordStates app = {(VDTPolicyRecordState)(bits & 3),
            (VDTPolicyRecordState)((bits >> 2) & 3), (VDTPolicyRecordState)((bits >> 4) & 3)};
        VDTResourceRecordStates ext = {(VDTPolicyRecordState)((bits >> 6) & 3),
            (VDTPolicyRecordState)((bits >> 8) & 3), (VDTPolicyRecordState)((bits >> 10) & 3)};
        for (unsigned identity = 0; identity < 2; ++identity) {
            VDTResourceRuleSelections result = VDTSelectResourceRules(identity != 0, app, ext);
            check_selection(identity != 0, app.cpu, ext.cpu, result.cpu);
            check_selection(identity != 0, app.memory, ext.memory, result.memory);
            check_selection(identity != 0, app.jetsam, ext.jetsam, result.jetsam);
        }
    }
    VDTResourceRuleSelection unknown = VDTSelectResourceRule(true, VDTPolicyRecordEnabled, (VDTPolicyRecordState)88);
    assert(unknown.origin == VDTPolicyOriginExtension && unknown.state == VDTPolicyRecordInvalid);
    unknown = VDTSelectResourceRule(true, (VDTPolicyRecordState)88, VDTPolicyRecordMissing);
    assert(unknown.origin == VDTPolicyOriginApp && unknown.state == VDTPolicyRecordInvalid);
    VDTResourceRecordStates app = {VDTPolicyRecordEnabled, VDTPolicyRecordEnabled, VDTPolicyRecordEnabled};
    VDTMemoryRule system = parse(VDTPolicyRecordEnabled, 0, 0);
    VDTResourceRecordStates ext = {VDTPolicyRecordMissing, system.state, VDTPolicyRecordMissing};
    VDTResourceRuleSelections result = VDTSelectResourceRules(true, app, ext);
    assert(result.cpu.origin == VDTPolicyOriginApp && result.jetsam.origin == VDTPolicyOriginApp);
    assert(result.memory.origin == VDTPolicyOriginExtension);
    assert(VDTPlanMemoryRule(&system, 22, false).status == VDTPolicyPlanNoWrite);
    ext.memory = VDTPolicyRecordDisabled;
    result = VDTSelectResourceRules(true, app, ext);
    assert(result.memory.origin == VDTPolicyOriginExtension && result.memory.state == VDTPolicyRecordDisabled);
    assert(result.cpu.origin == VDTPolicyOriginApp && result.jetsam.origin == VDTPolicyOriginApp);
}

int main(void) {
    test_typed_inputs();
    test_modes_and_plans();
    test_records_and_transitions();
    test_resource_inheritance();
    puts("memory production core PASS: typed inputs, 9 mode pairs x 8 OS x 2 histories (including future majors), 8192 resource/identity tuples; recorder only");
    return 0;
}
