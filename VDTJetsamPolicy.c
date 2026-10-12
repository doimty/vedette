// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTJetsamPolicy.h"
#include <stddef.h>

typedef struct {
    VDTJetsamNamedBand name;
    int32_t darwin21;
    int32_t darwin22Plus;
    int32_t firstDarwin;
    VDTJetsamBandClass bandClass;
} NamedBand;
// Explicit verified definitions: XNU 8019.41.5, 8792.41.9, 10002.1.13,
// 11215.1.10 bsd/sys/kern_memorystatus.h. No numeric scale conversion.
static const NamedBand namedBands[] = {
    {VDTJetsamNamedIdle, 0, 0, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedBackground, 3, 30, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedMail, 4, 40, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedPhone, 5, 50, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedUISupport, 8, 80, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedForegroundSupport, 9, 90, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedForeground, 10, 100, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedAudioAndAccessory, 12, 120, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedConductor, 13, 130, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedDriverApple, 15, 150, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedHome, 16, 160, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedExecutive, 17, 170, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedImportant, 18, 180, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedCritical, 19, 190, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedMaximum, 21, 210, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedDefault, 18, 180, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedTelephony, 19, 190, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedElevatedInactive, 4, 40, 21, VDTJetsamBandNamedDefined},
    {VDTJetsamNamedIdleDeferred, 1, 10, 21, VDTJetsamBandManagedReserved},
    {VDTJetsamNamedBackgroundOpportunistic, 2, 20, 21, VDTJetsamBandManagedReserved},
    {VDTJetsamNamedFreezer, 0, 75, 22, VDTJetsamBandManagedReserved},
    {VDTJetsamNamedAgingBand1Stuck, 0, 15, 24, VDTJetsamBandManagedReserved}
};

static const NamedBand *findNamed(VDTJetsamNamedBand name) {
    for (size_t i = 0; i < sizeof(namedBands) / sizeof(namedBands[0]); ++i) {
        if (namedBands[i].name == name) return &namedBands[i];
    }
    return NULL;
}

VDTJetsamRule VDTParseJetsamRule(const VDTJetsamRuleInput *input) {
    VDTJetsamRule result = {VDTPolicyRecordInvalid, VDTPolicyParseInvalidArgument,
        VDTJetsamModeInvalid, VDTJetsamNamedInvalid, 0, 0};
    if (!input) return result;
    if (input->state == VDTPolicyRecordMissing) {
        result.state = VDTPolicyRecordMissing;
        result.parseStatus = VDTPolicyParseOK;
        return result;
    }
    if (input->state != VDTPolicyRecordEnabled && input->state != VDTPolicyRecordDisabled) {
        result.parseStatus = VDTPolicyParseInvalidRecord;
        return result;
    }
    int32_t schema = 0;
    result.parseStatus = VDTPolicyReadInt32(input->schema, &schema);
    if (result.parseStatus != VDTPolicyParseOK) return result;
    if (schema != VDT_RESOURCE_POLICY_SCHEMA_VERSION) {
        result.parseStatus = VDTPolicyParseUnknownSchema;
        return result;
    }
    if (input->state == VDTPolicyRecordDisabled) {
        result.state = VDTPolicyRecordDisabled;
        return result;
    }
    switch (input->mode) {
        case VDTJetsamModeSystem: break;
        case VDTJetsamModeNamed:
            if (!findNamed(input->named)) {
                result.parseStatus = VDTPolicyParseUnknownMode;
                return result;
            }
            result.named = input->named;
            break;
        case VDTJetsamModeRaw:
            result.parseStatus = VDTPolicyReadInt32(input->rawBand, &result.rawBand);
            if (result.parseStatus != VDTPolicyParseOK) return result;
            result.parseStatus = VDTPolicyReadInt32(input->rawSourceDarwinMajor, &result.rawSourceDarwinMajor);
            if (result.parseStatus != VDTPolicyParseOK) return result;
            if (result.rawSourceDarwinMajor <= 0) {
                result.parseStatus = VDTPolicyParseOutOfRange;
                return result;
            }
            break;
        default:
            result.parseStatus = VDTPolicyParseUnknownMode;
            return result;
    }
    result.mode = input->mode;
    result.state = VDTPolicyRecordEnabled;
    return result;
}

bool VDTJetsamMaxBand(int32_t major, int32_t *out) {
    if (!out) return false;
    *out = 0;
    if (!VDTPolicyDarwinMajorIsKnown(major)) return false;
    *out = major == 21 ? 21 : 210;
    return true;
}

VDTJetsamBandClass VDTClassifyJetsamBand(int32_t major, int32_t band) {
    int32_t max = 0;
    if (!VDTJetsamMaxBand(major, &max)) return VDTJetsamBandInvalid;
    if (band == -1 || band == -2) return VDTJetsamBandSpecialSet;
    // INTERNAL is defined in Darwin24 (launchd/kernel_task), not a public band.
    // 999 is denied on every verified version, never normalized to MAX.
    if (band == 999) return VDTJetsamBandInternal;
    if (band < 0 || band > max) return VDTJetsamBandInvalid;
    if (major >= 22 && band >= 1 && band <= 9) return VDTJetsamBandManagedReserved;
    for (size_t i = 0; i < sizeof(namedBands) / sizeof(namedBands[0]); ++i) {
        const NamedBand *entry = &namedBands[i];
        if (major < entry->firstDarwin) continue;
        int32_t value = major == 21 ? entry->darwin21 : entry->darwin22Plus;
        if (band == value) return entry->bandClass;
    }
    return VDTJetsamBandUnnamedAdvanced;
}

VDTJetsamPlan VDTPlanJetsamRule(const VDTJetsamRule *rule,
    int32_t targetDarwinMajor, bool priorOverride) {
    VDTJetsamPlan plan = {VDTPolicyPlanInvalid, VDTPolicyReasonInvalidInput,
        priorOverride, VDTJetsamBandInvalid, false, 0};
    if (!rule || rule->parseStatus != VDTPolicyParseOK ||
        (rule->state != VDTPolicyRecordMissing && rule->state != VDTPolicyRecordDisabled &&
         rule->state != VDTPolicyRecordEnabled)) return plan;
    if (rule->state == VDTPolicyRecordEnabled &&
        (rule->mode != VDTJetsamModeSystem && rule->mode != VDTJetsamModeNamed &&
         rule->mode != VDTJetsamModeRaw)) return plan;
    if (!VDTPolicyDarwinMajorIsKnown(targetDarwinMajor)) {
        plan.status = VDTPolicyPlanReadOnly;
        plan.reason = VDTPolicyReasonUnknownTargetOS;
        return plan;
    }
    if (rule->state == VDTPolicyRecordMissing || rule->state == VDTPolicyRecordDisabled ||
        rule->mode == VDTJetsamModeSystem) {
        plan.status = priorOverride ? VDTPolicyPlanRestoreRequired : VDTPolicyPlanNoWrite;
        plan.reason = priorOverride ? VDTPolicyReasonRestoreUnverified : VDTPolicyReasonNone;
        return plan;
    }
    int32_t band = 0;
    if (rule->mode == VDTJetsamModeNamed) {
        const NamedBand *entry = findNamed(rule->named);
        if (!entry) return plan;
        if (targetDarwinMajor < entry->firstDarwin) {
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonNamedBandUnavailable;
            return plan;
        }
        band = targetDarwinMajor == 21 ? entry->darwin21 : entry->darwin22Plus;
    } else {
        if (!VDTPolicyDarwinMajorIsKnown(rule->rawSourceDarwinMajor)) {
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonUnknownSourceOS;
            return plan;
        }
        if (rule->rawSourceDarwinMajor != targetDarwinMajor) {
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonRawVersionMismatch;
            return plan;
        }
        band = rule->rawBand;
    }
    plan.bandClass = VDTClassifyJetsamBand(targetDarwinMajor, band);
    switch (plan.bandClass) {
        case VDTJetsamBandNamedDefined:
            plan.status = VDTPolicyPlanReady;
            plan.reason = VDTPolicyReasonNone;
            plan.hasBand = true;
            plan.band = band;
            break;
        case VDTJetsamBandManagedReserved:
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonManagedBand;
            break;
        case VDTJetsamBandUnnamedAdvanced:
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonUnnamedBand;
            break;
        case VDTJetsamBandInternal:
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonInternalBand;
            break;
        case VDTJetsamBandSpecialSet:
            plan.status = VDTPolicyPlanUnsupported;
            plan.reason = VDTPolicyReasonSpecialSetValue;
            break;
        default: break;
    }
    return plan;
}
