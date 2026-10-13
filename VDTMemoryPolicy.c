// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTMemoryPolicy.h"
#include <stddef.h>

VDTPolicyParseStatus VDTPolicyReadInt32(VDTPolicyInteger input, int32_t *out) {
    if (!out) return VDTPolicyParseInvalidArgument;
    *out = 0;
    if (input.tag != VDTPolicyInputInteger) return VDTPolicyParseInvalidType;
    if (input.value < INT32_MIN || input.value > INT32_MAX) return VDTPolicyParseOutOfRange;
    *out = (int32_t)input.value;
    return VDTPolicyParseOK;
}

bool VDTPolicyDarwinMajorIsKnown(int32_t major) {
    return major == 21 || major == 22 || major == 23 || major == 24;
}

static bool recordStateValid(VDTPolicyRecordState state) {
    return state == VDTPolicyRecordMissing || state == VDTPolicyRecordDisabled ||
        state == VDTPolicyRecordEnabled || state == VDTPolicyRecordInvalid;
}

VDTPolicyParseStatus VDTParseMemoryLimit(VDTPolicyInteger input, VDTMemoryLimit *out) {
    if (!out) return VDTPolicyParseInvalidArgument;
    *out = (VDTMemoryLimit){VDTMemoryModeInvalid, 0};
    int32_t value = 0;
    VDTPolicyParseStatus status = VDTPolicyReadInt32(input, &value);
    if (status != VDTPolicyParseOK) return status;
    if (value < -1) return VDTPolicyParseOutOfRange;
    if (value == -1) {
        out->mode = VDTMemoryModeUnlimited;
    } else if (value == 0) {
        out->mode = VDTMemoryModeSystem;
    } else {
        out->mode = VDTMemoryModeCustom;
        out->mib = value;
    }
    return VDTPolicyParseOK;
}

VDTMemoryRule VDTParseMemoryRule(const VDTMemoryRuleInput *input) {
    VDTMemoryRule result = {VDTPolicyRecordInvalid, VDTPolicyParseInvalidArgument,
        {VDTMemoryModeInvalid, 0}, {VDTMemoryModeInvalid, 0}};
    if (!input) return result;
    if (!recordStateValid(input->state) || input->state == VDTPolicyRecordInvalid) {
        result.parseStatus = VDTPolicyParseInvalidRecord;
        return result;
    }
    if (input->state == VDTPolicyRecordMissing) {
        result.state = VDTPolicyRecordMissing;
        result.parseStatus = VDTPolicyParseOK;
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
        return result; // values are not required for an explicit off record
    }
    VDTPolicyParseStatus activeStatus = VDTParseMemoryLimit(input->active, &result.active);
    VDTPolicyParseStatus inactiveStatus = VDTParseMemoryLimit(input->inactive, &result.inactive);
    result.parseStatus = activeStatus != VDTPolicyParseOK ? activeStatus : inactiveStatus;
    if (result.parseStatus == VDTPolicyParseOK) result.state = VDTPolicyRecordEnabled;
    return result;
}

static bool limitValid(VDTMemoryLimit limit) {
    switch (limit.mode) {
        case VDTMemoryModeSystem:
        case VDTMemoryModeUnlimited: return limit.mib == 0;
        case VDTMemoryModeCustom: return limit.mib > 0;
        default: return false;
    }
}

VDTMemoryPlan VDTPlanMemoryRule(const VDTMemoryRule *rule,
    int32_t targetDarwinMajor, bool priorOverride) {
    VDTMemoryPlan plan = {VDTPolicyPlanInvalid, VDTPolicyReasonInvalidInput,
        priorOverride, false, 0, 0};
    if (!rule || rule->parseStatus != VDTPolicyParseOK || !recordStateValid(rule->state) ||
        rule->state == VDTPolicyRecordInvalid) return plan;
    if (rule->state == VDTPolicyRecordEnabled &&
        (!limitValid(rule->active) || !limitValid(rule->inactive))) return plan;
    if (!VDTPolicyDarwinMajorIsKnown(targetDarwinMajor)) {
        plan.status = VDTPolicyPlanReadOnly;
        plan.reason = VDTPolicyReasonUnknownTargetOS;
        return plan;
    }
    if (rule->state == VDTPolicyRecordMissing || rule->state == VDTPolicyRecordDisabled ||
        (rule->active.mode == VDTMemoryModeSystem && rule->inactive.mode == VDTMemoryModeSystem)) {
        plan.status = priorOverride ? VDTPolicyPlanRestoreRequired : VDTPolicyPlanNoWrite;
        plan.reason = priorOverride ? VDTPolicyReasonRestoreUnverified : VDTPolicyReasonNone;
        return plan;
    }
    if (rule->active.mode == VDTMemoryModeUnlimited || rule->inactive.mode == VDTMemoryModeUnlimited) {
        plan.status = VDTPolicyPlanUnsupported;
        plan.reason = VDTPolicyReasonUnlimitedUnverified;
        return plan;
    }
    if (rule->active.mode == VDTMemoryModeSystem || rule->inactive.mode == VDTMemoryModeSystem) {
        plan.status = VDTPolicyPlanUnsupported;
        plan.reason = VDTPolicyReasonMixedSystemUnverified;
        return plan;
    }
    plan.status = VDTPolicyPlanReady;
    plan.reason = VDTPolicyReasonNone;
    plan.hasCustomPair = true;
    plan.activeMiB = rule->active.mib;
    plan.inactiveMiB = rule->inactive.mib;
    return plan;
}

VDTResourceRuleSelection VDTSelectResourceRule(bool extensionIdentityValid,
    VDTPolicyRecordState app, VDTPolicyRecordState extension) {
    VDTResourceRuleSelection result = {VDTPolicyOriginNone, VDTPolicyRecordMissing};
    if (!extensionIdentityValid) {
        result.state = VDTPolicyRecordInvalid;
        return result;
    }
    if (!recordStateValid(app)) app = VDTPolicyRecordInvalid;
    if (!recordStateValid(extension)) extension = VDTPolicyRecordInvalid;
    if (extension != VDTPolicyRecordMissing) {
        result.origin = VDTPolicyOriginExtension;
        result.state = extension;
    } else if (app != VDTPolicyRecordMissing) {
        result.origin = VDTPolicyOriginApp;
        result.state = app;
    }
    return result;
}

VDTResourceRuleSelections VDTSelectResourceRules(bool extensionIdentityValid,
    VDTResourceRecordStates app, VDTResourceRecordStates extension) {
    VDTResourceRuleSelections result;
    result.cpu = VDTSelectResourceRule(extensionIdentityValid, app.cpu, extension.cpu);
    result.memory = VDTSelectResourceRule(extensionIdentityValid, app.memory, extension.memory);
    result.jetsam = VDTSelectResourceRule(extensionIdentityValid, app.jetsam, extension.jetsam);
    return result;
}
