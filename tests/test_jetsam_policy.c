// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTJetsamPolicy.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>

static const int32_t versions[] = {21, 22, 23, 24, 25, 26, 30, INT32_MAX};

static VDTPolicyInteger integer(int64_t value) { return (VDTPolicyInteger){VDTPolicyInputInteger, value}; }
static VDTJetsamRule rawRule(int64_t band, int64_t source) {
    VDTJetsamRuleInput in = {VDTPolicyRecordEnabled, integer(1), VDTJetsamModeRaw,
        VDTJetsamNamedInvalid, integer(band), integer(source)};
    return VDTParseJetsamRule(&in);
}
static VDTJetsamRule namedRule(VDTJetsamNamedBand name) {
    VDTJetsamRuleInput in = {VDTPolicyRecordEnabled, integer(1), VDTJetsamModeNamed,
        name, integer(0), integer(0)};
    return VDTParseJetsamRule(&in);
}
// Recorder only: no GET, SET, memory command, process attachment or helper.
typedef struct { unsigned count; int32_t lastBand; } FakeRecorder;
static void record(FakeRecorder *fake, VDTJetsamPlan plan) {
    if (plan.status != VDTPolicyPlanReady) {
        assert(!plan.hasBand && plan.band == 0);
        return;
    }
    assert(plan.hasBand && plan.band >= 0 && plan.bandClass == VDTJetsamBandNamedDefined);
    fake->count++; fake->lastBand = plan.band;
}

static void test_named(void) {
    const struct { VDTJetsamNamedBand name; int32_t old; int32_t modern; } cases[] = {
        {VDTJetsamNamedIdle, 0, 0}, {VDTJetsamNamedBackground, 3, 30},
        {VDTJetsamNamedMail, 4, 40}, {VDTJetsamNamedPhone, 5, 50},
        {VDTJetsamNamedUISupport, 8, 80}, {VDTJetsamNamedForegroundSupport, 9, 90},
        {VDTJetsamNamedForeground, 10, 100}, {VDTJetsamNamedAudioAndAccessory, 12, 120},
        {VDTJetsamNamedConductor, 13, 130}, {VDTJetsamNamedDriverApple, 15, 150},
        {VDTJetsamNamedHome, 16, 160}, {VDTJetsamNamedExecutive, 17, 170},
        {VDTJetsamNamedImportant, 18, 180}, {VDTJetsamNamedCritical, 19, 190},
        {VDTJetsamNamedMaximum, 21, 210}, {VDTJetsamNamedDefault, 18, 180},
        {VDTJetsamNamedTelephony, 19, 190}, {VDTJetsamNamedElevatedInactive, 4, 40}
    };
    FakeRecorder fake = {0, -1};
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        VDTJetsamRule rule = namedRule(cases[i].name);
        assert(rule.parseStatus == VDTPolicyParseOK && rule.named == cases[i].name);
        for (size_t v = 0; v < sizeof(versions) / sizeof(versions[0]); ++v) {
            const int32_t os = versions[v];
            VDTJetsamPlan plan = VDTPlanJetsamRule(&rule, os, false);
            assert(plan.status == VDTPolicyPlanReady && plan.reason == VDTPolicyReasonNone);
            assert(plan.band == (os == 21 ? cases[i].old : cases[i].modern));
            record(&fake, plan);
        }
        assert(rule.named == cases[i].name); // mapping must not replace saved semantics
    }
    assert(fake.count == 18 * (sizeof(versions) / sizeof(versions[0])));
    const VDTJetsamNamedBand reserved[] = {VDTJetsamNamedIdleDeferred,
        VDTJetsamNamedBackgroundOpportunistic, VDTJetsamNamedFreezer, VDTJetsamNamedAgingBand1Stuck};
    for (size_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); ++i) {
        VDTJetsamRule rule = namedRule(reserved[i]);
        assert(rule.parseStatus == VDTPolicyParseOK);
        for (size_t v = 0; v < sizeof(versions) / sizeof(versions[0]); ++v) {
            const int32_t os = versions[v];
            VDTJetsamPlan plan = VDTPlanJetsamRule(&rule, os, true);
            bool unavailable = (reserved[i] == VDTJetsamNamedFreezer && os == 21) ||
                (reserved[i] == VDTJetsamNamedAgingBand1Stuck && os < 24);
            assert(plan.status == VDTPolicyPlanUnsupported && plan.priorOverride);
            assert(plan.reason == (unavailable ? VDTPolicyReasonNamedBandUnavailable : VDTPolicyReasonManagedBand));
            record(&fake, plan);
        }
    }
    assert(fake.count == 18 * (sizeof(versions) / sizeof(versions[0])));
}

static VDTJetsamBandClass expected_class(int32_t os, int32_t band) {
    const int32_t old[] = {0, 3, 4, 5, 8, 9, 10, 12, 13, 15, 16, 17, 18, 19, 21};
    const int32_t modern[] = {0, 30, 40, 50, 80, 90, 100, 120, 130, 150, 160, 170, 180, 190, 210};
    if (band == -1 || band == -2) return VDTJetsamBandSpecialSet;
    if (band == 999) return VDTJetsamBandInternal;
    if (band < 0 || band > (os == 21 ? 21 : 210)) return VDTJetsamBandInvalid;
    if (os == 21 && (band == 1 || band == 2)) return VDTJetsamBandManagedReserved;
    if (os >= 22 && ((band >= 1 && band <= 10) || band == 20 || band == 75 || (os >= 24 && band == 15)))
        return VDTJetsamBandManagedReserved;
    for (size_t i = 0; i < sizeof(old) / sizeof(old[0]); ++i) {
        if (band == (os == 21 ? old[i] : modern[i])) return VDTJetsamBandNamedDefined;
    }
    return VDTJetsamBandUnnamedAdvanced;
}

static void test_raw_and_boundaries(void) {
    FakeRecorder fake = {0, -1};
    for (size_t v = 0; v < sizeof(versions) / sizeof(versions[0]); ++v) {
        const int32_t os = versions[v];
        int32_t max = -1;
        assert(VDTJetsamMaxBand(os, &max) && max == (os == 21 ? 21 : 210));
        for (int32_t band = -3; band <= max + 1; ++band) {
            VDTJetsamRule rule = rawRule(band, os);
            VDTJetsamPlan plan = VDTPlanJetsamRule(&rule, os, false);
            VDTJetsamBandClass wanted = expected_class(os, band);
            assert(rule.parseStatus == VDTPolicyParseOK && rule.rawBand == band && rule.rawSourceDarwinMajor == os);
            assert(VDTClassifyJetsamBand(os, band) == wanted && plan.bandClass == wanted);
            VDTPolicyPlanStatus status = wanted == VDTJetsamBandNamedDefined ? VDTPolicyPlanReady :
                wanted == VDTJetsamBandInvalid ? VDTPolicyPlanInvalid : VDTPolicyPlanUnsupported;
            assert(plan.status == status);
            if (status == VDTPolicyPlanReady) assert(plan.band == band);
            record(&fake, plan);
        }
        VDTJetsamRule internal = rawRule(999, os);
        VDTJetsamPlan plan = VDTPlanJetsamRule(&internal, os, true);
        assert(plan.status == VDTPolicyPlanUnsupported && plan.reason == VDTPolicyReasonInternalBand && plan.priorOverride);
        record(&fake, plan);
    }
    const int32_t special[] = {75, 90, 150, 210};
    for (size_t i = 0; i < sizeof(special) / sizeof(special[0]); ++i) {
        for (size_t s = 0; s < sizeof(versions) / sizeof(versions[0]); ++s) {
            const int32_t source = versions[s];
            VDTJetsamRule rule = rawRule(special[i], source);
            for (size_t t = 0; t < sizeof(versions) / sizeof(versions[0]); ++t) {
                const int32_t target = versions[t];
                VDTJetsamPlan plan = VDTPlanJetsamRule(&rule, target, false);
                assert(rule.rawBand == special[i] && rule.rawSourceDarwinMajor == source);
                if (target != source) {
                    assert(plan.status == VDTPolicyPlanUnsupported && plan.reason == VDTPolicyReasonRawVersionMismatch);
                } else if (source == 21) assert(plan.status == VDTPolicyPlanInvalid);
                else if (special[i] == 75) {
                    assert(plan.status == VDTPolicyPlanUnsupported && plan.reason == VDTPolicyReasonManagedBand);
                    assert(plan.bandClass == VDTJetsamBandManagedReserved);
                } else assert(plan.status == VDTPolicyPlanReady && plan.band == special[i]);
                record(&fake, plan);
            }
        }
    }
    const int64_t extremes[] = {INT32_MIN, INT32_MAX};
    for (size_t i = 0; i < 2; ++i) {
        VDTJetsamRule rule = rawRule(extremes[i], 22);
        assert(VDTPlanJetsamRule(&rule, 22, false).status == VDTPolicyPlanInvalid);
    }
}

static void test_typed_and_unknown(void) {
    VDTJetsamRuleInput input = {VDTPolicyRecordEnabled, integer(1), VDTJetsamModeRaw,
        VDTJetsamNamedInvalid, integer(90), integer(22)};
    const VDTPolicyInputTag badTags[] = {VDTPolicyInputInvalid, VDTPolicyInputBoolean,
        VDTPolicyInputNull, VDTPolicyInputString, VDTPolicyInputFloatingPoint,
        VDTPolicyInputOverflow, (VDTPolicyInputTag)91};
    for (size_t i = 0; i < sizeof(badTags) / sizeof(badTags[0]); ++i) {
        input.rawBand = (VDTPolicyInteger){badTags[i], 1};
        VDTJetsamRule rule = VDTParseJetsamRule(&input);
        assert(rule.state == VDTPolicyRecordInvalid && rule.parseStatus == VDTPolicyParseInvalidType);
        input.rawBand = integer(90); input.rawSourceDarwinMajor = (VDTPolicyInteger){badTags[i], 22};
        rule = VDTParseJetsamRule(&input);
        assert(rule.state == VDTPolicyRecordInvalid && rule.parseStatus == VDTPolicyParseInvalidType);
        input.rawSourceDarwinMajor = integer(22);
    }
    const int64_t overflow[] = {INT64_MIN, (int64_t)INT32_MAX + 1, INT64_MAX};
    for (size_t i = 0; i < 3; ++i) {
        assert(rawRule(overflow[i], 22).parseStatus == VDTPolicyParseOutOfRange);
        assert(rawRule(90, overflow[i]).parseStatus == VDTPolicyParseOutOfRange);
    }
    assert(rawRule(90, 0).parseStatus == VDTPolicyParseOutOfRange);
    assert(rawRule(90, -1).parseStatus == VDTPolicyParseOutOfRange);
    input.schema = integer(3);
    assert(VDTParseJetsamRule(&input).parseStatus == VDTPolicyParseUnknownSchema);
    input.schema = (VDTPolicyInteger){VDTPolicyInputBoolean, 1};
    assert(VDTParseJetsamRule(&input).parseStatus == VDTPolicyParseInvalidType);
    input.schema = integer(1); input.mode = (VDTJetsamMode)91;
    assert(VDTParseJetsamRule(&input).parseStatus == VDTPolicyParseUnknownMode);
    assert(namedRule(VDTJetsamNamedInvalid).parseStatus == VDTPolicyParseUnknownMode);
    assert(namedRule((VDTJetsamNamedBand)91).parseStatus == VDTPolicyParseUnknownMode);
    input.state = (VDTPolicyRecordState)99;
    assert(VDTParseJetsamRule(&input).parseStatus == VDTPolicyParseInvalidRecord);
    assert(VDTParseJetsamRule(NULL).parseStatus == VDTPolicyParseInvalidArgument);
    assert(VDTPlanJetsamRule(NULL, 22, true).status == VDTPolicyPlanInvalid);
    assert(!VDTJetsamMaxBand(21, NULL));
    const int32_t unknown[] = {0, -1, 20};
    FakeRecorder fake = {0, -1};
    for (size_t i = 0; i < sizeof(unknown) / sizeof(unknown[0]); ++i) {
        int32_t max = 123;
        assert(!VDTJetsamMaxBand(unknown[i], &max) && max == 0);
        assert(VDTClassifyJetsamBand(unknown[i], 0) == VDTJetsamBandInvalid);
        VDTJetsamRule named = namedRule(VDTJetsamNamedForeground);
        VDTJetsamPlan plan = VDTPlanJetsamRule(&named, unknown[i], true);
        assert(plan.status == VDTPolicyPlanReadOnly && plan.reason == VDTPolicyReasonUnknownTargetOS && plan.priorOverride);
        record(&fake, plan);
        if (unknown[i] > 0) {
            VDTJetsamRule raw = rawRule(90, unknown[i]);
            assert(raw.parseStatus == VDTPolicyParseOK);
            plan = VDTPlanJetsamRule(&raw, 22, false);
            assert(plan.status == VDTPolicyPlanUnsupported && plan.reason == VDTPolicyReasonUnknownSourceOS);
            record(&fake, plan);
        }
    }
    assert(fake.count == 0);
}

static void test_system_disabled_invalid(void) {
    VDTJetsamRuleInput input = {VDTPolicyRecordEnabled, integer(1), VDTJetsamModeSystem,
        VDTJetsamNamedInvalid, integer(-1), integer(21)};
    VDTJetsamRule system = VDTParseJetsamRule(&input);
    assert(system.state == VDTPolicyRecordEnabled && system.mode == VDTJetsamModeSystem);
    assert(system.rawBand == 0 && system.rawSourceDarwinMajor == 0);
    VDTJetsamRule idle = namedRule(VDTJetsamNamedIdle);
    VDTJetsamPlan idlePlan = VDTPlanJetsamRule(&idle, 22, false);
    assert(idlePlan.status == VDTPolicyPlanReady && idlePlan.hasBand && idlePlan.band == 0);
    VDTJetsamRule rawIdle = rawRule(0, 22);
    assert(VDTPlanJetsamRule(&rawIdle, 22, false).hasBand);
    const VDTPolicyRecordState states[] = {VDTPolicyRecordEnabled, VDTPolicyRecordDisabled, VDTPolicyRecordMissing};
    FakeRecorder fake = {0, -1};
    for (size_t i = 0; i < 3; ++i) {
        input.state = states[i];
        VDTJetsamRule rule = VDTParseJetsamRule(&input);
        assert(rule.state == states[i] && rule.parseStatus == VDTPolicyParseOK);
        for (unsigned prior = 0; prior < 2; ++prior) {
            VDTJetsamPlan plan = VDTPlanJetsamRule(&rule, 22, prior != 0);
            assert(plan.status == (prior ? VDTPolicyPlanRestoreRequired : VDTPolicyPlanNoWrite));
            assert(plan.reason == (prior ? VDTPolicyReasonRestoreUnverified : VDTPolicyReasonNone));
            assert(plan.priorOverride == (prior != 0));
            record(&fake, plan);
        }
        if (states[i] != VDTPolicyRecordMissing) {
            VDTResourceRuleSelection chosen = VDTSelectResourceRule(true, VDTPolicyRecordEnabled, rule.state);
            assert(chosen.origin == VDTPolicyOriginExtension);
        }
    }
    input.state = VDTPolicyRecordInvalid;
    VDTJetsamRule invalid = VDTParseJetsamRule(&input);
    assert(invalid.state == VDTPolicyRecordInvalid && invalid.parseStatus == VDTPolicyParseInvalidRecord);
    VDTJetsamPlan plan = VDTPlanJetsamRule(&invalid, 22, true);
    assert(plan.status == VDTPolicyPlanInvalid && plan.priorOverride);
    record(&fake, plan);
    VDTResourceRuleSelection chosen = VDTSelectResourceRule(true, VDTPolicyRecordEnabled, invalid.state);
    assert(chosen.origin == VDTPolicyOriginExtension && chosen.state == VDTPolicyRecordInvalid);
    VDTJetsamRule special = rawRule(-1, 22);
    plan = VDTPlanJetsamRule(&special, 22, false);
    assert(plan.status == VDTPolicyPlanUnsupported && plan.reason == VDTPolicyReasonSpecialSetValue);
    record(&fake, plan);
    assert(fake.count == 0);
}

int main(void) {
    test_named();
    test_raw_and_boundaries();
    test_typed_and_unknown();
    test_system_disabled_invalid();
    puts("jetsam production core PASS: named semantics and exhaustive band boundaries x 8 OS, raw75/90/150/210 provenance x 8 sources x 8 targets, typed/system/unknown OS; recorder only");
    return 0;
}
