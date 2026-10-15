// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultModel.h"
#import <CoreFoundation/CoreFoundation.h>
#include "../VDTResourceApply.h"
#include <errno.h>
#include <math.h>
#include <string.h>

static NSDictionary *VDTCheckDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSString *VDTCheckString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] <= 4096 ? value : nil;
}
static NSNumber *VDTCheckInteger(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    const char *type = [value objCType];
    if (!type || strlen(type) != 1 || !strchr("cCsSiIlLqQ", type[0])) return nil;
    // All displayed integer fields fit within this exact representable interval.
    double number = [value doubleValue];
    return isfinite(number) && number >= INT32_MIN && number <= UINT32_MAX ? value : nil;
}
static BOOL VDTCheckTrue(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue];
}
static BOOL VDTCheckFalse(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && ![value boolValue];
}
static NSString *VDTCheckText(VDTCheckLocalizer localize, NSString *key) {
    return localize ? (localize(key) ?: key) : key;
}
static NSString *VDTCheckDate(id raw) {
    if ([raw isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)raw) != CFBooleanGetTypeID()) {
        double seconds = [raw doubleValue];
        if (isfinite(seconds) && seconds > 0 && seconds < 253402300800.0)
            return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds]
                dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
    }
    return nil;
}
static id VDTCheckTimeValue(NSDictionary *receipt, BOOL nice) {
    return nice ? (receipt[@"oldestCheckedAt"] ?: receipt[@"checkedAt"]) : receipt[@"checkedAt"];
}
static NSString *VDTCheckTime(NSDictionary *receipt, BOOL nice, VDTCheckLocalizer localize) {
    NSString *stamp = VDTCheckDate(VDTCheckTimeValue(receipt, nice));
    return stamp ? [NSString stringWithFormat:VDTCheckText(localize, @"Last check: %@"), stamp]
        : VDTCheckText(localize, @"Check time not recorded");
}
static NSArray *VDTCheckPair(id raw) {
    if (![raw isKindOfClass:NSArray.class] || [raw count] != 4) return nil;
    for (id field in raw) if (!VDTCheckInteger(field)) return nil;
    if ([raw[0] longLongValue] > INT32_MAX || [raw[2] longLongValue] > INT32_MAX ||
        [raw[1] longLongValue] < 0 || [raw[3] longLongValue] < 0) return nil;
    return raw;
}
static NSString *VDTCheckMemoryReadback(id raw, VDTCheckLocalizer localize) {
    NSArray *pair = VDTCheckPair(raw);
    if (!pair) return VDTCheckText(localize, @"Not recorded");
    // Only the full, evidence-backed pair represents unlimited. One large limit,
    // nonzero attributes or a raw -1 must never be translated as unlimited.
    if ([pair[0] longLongValue] == VDT_APPLY_UNLIMITED_LIMIT &&
        [pair[1] longLongValue] == VDT_APPLY_UNLIMITED_ATTRS &&
        [pair[2] longLongValue] == VDT_APPLY_UNLIMITED_LIMIT &&
        [pair[3] longLongValue] == VDT_APPLY_UNLIMITED_ATTRS)
        return VDTCheckText(localize, @"Unlimited / Unlimited");
    return [NSString stringWithFormat:@"%@ / %@ MiB", pair[0], pair[2]];
}
static NSString *VDTCheckTarget(NSDictionary *rule, BOOL memory, BOOL nice, VDTCheckLocalizer localize) {
    if (!rule) return VDTCheckText(localize, @"Not configured");
    id enabled = rule[nice ? @"requestedEnabled" : @"enabled"];
    if (VDTCheckFalse(enabled)) return VDTCheckText(localize, @"Off");
    if (!VDTCheckTrue(enabled)) return VDTCheckText(localize, @"Incomplete settings");
    if (nice) {
        NSNumber *number = VDTCheckInteger(rule[@"value"]);
        if (!VDTCheckTrue(rule[@"valid"]) || !number || number.longLongValue < -20 || number.longLongValue > 20)
            return VDTCheckText(localize, @"Incomplete settings");
        return number.stringValue;
    }
    if (!memory) {
        NSNumber *number = VDTCheckInteger(rule[@"priority"]);
        return number && number.longLongValue <= INT32_MAX ? number.stringValue : VDTCheckText(localize, @"Incomplete settings");
    }
    NSNumber *active = VDTCheckInteger(rule[@"active"]), *inactive = VDTCheckInteger(rule[@"inactive"]);
    if (!active || !inactive) return VDTCheckText(localize, @"Incomplete settings");
    if (active.longLongValue == -1 && inactive.longLongValue == -1)
        return VDTCheckText(localize, @"Unlimited / Unlimited");
    if (active.longLongValue == 0 && inactive.longLongValue == 0)
        return VDTCheckText(localize, @"Restore recorded value");
    if (active.longLongValue > 0 && active.longLongValue <= INT32_MAX &&
        inactive.longLongValue > 0 && inactive.longLongValue <= INT32_MAX)
        return [NSString stringWithFormat:@"%@ / %@ MiB", active, inactive];
    return VDTCheckText(localize, @"Incompatible settings");
}
static NSString *VDTCheckNiceState(NSDictionary *receipt) {
    NSDictionary *labels = @{
        @"applied": @"Nice state applied", @"restored": @"Nice state restored",
        @"disabled": @"Nice state disabled", @"pending": @"Nice state pending",
        @"target-not-running": @"No verified running instance", @"identity-unavailable": @"Nice state identity unavailable",
        @"read-failed": @"Nice state read failed", @"write-failed": @"Nice state write failed",
        @"verify-failed": @"Nice state verify failed", @"store-failed": @"Nice state store failed",
        @"conflict": @"Nice state conflict", @"invalid": @"Nice state invalid", @"protected": @"Nice state protected",
        @"state-unavailable": @"Nice state unavailable", @"boot-unavailable": @"Nice state boot unavailable",
        @"paused": @"Nice state paused"};
    if (!receipt) return @"Waiting for execution result";
    if ([VDTCheckString(receipt[@"state"]) isEqual:@"receipt-unavailable"])
        return VDTCheckInteger(receipt[@"error"]).longLongValue == EFBIG
            ? @"Nice receipt exceeds size limit" : @"Nice receipt unavailable";
    return labels[VDTCheckString(receipt[@"state"]) ?: @""] ?: @"Nice state unavailable";
}

static NSString *VDTCheckResourceState(NSDictionary *receipt, NSString *side) {
    if (!receipt) return @"No matching resource receipt";
    NSString *overall = VDTCheckString(receipt[@"state"]);
    if ([overall isEqual:@"store-error"]) return @"Resource journal unavailable";
    NSDictionary *labels = @{@"applied": @"Rule readback matched", @"restored": @"Recorded values restored",
        @"conflict": @"Changed; not overwritten", @"unverified": @"Resource write not verified",
        @"restore-pending": @"Restoration pending", @"pending": @"Resource work pending",
        @"read-failed": @"Readback failed", @"store-error": @"Resource journal unavailable"};
    NSString *perSide = VDTCheckString(receipt[side]);
    if (labels[perSide ?: @""]) return labels[perSide];
    NSNumber *skip = VDTCheckInteger(receipt[[side stringByAppendingString:@"ExecutionSkip"]])
        ?: VDTCheckInteger(receipt[[side stringByAppendingString:@"PlanSkip"]])
        ?: VDTCheckInteger(receipt[[side stringByAppendingString:@"Skip"]]);
    if (skip) {
        switch (skip.longLongValue) {
            case VDTApplySkipUnsupported: return @"Rule not applied";
            case VDTApplySkipReadOnly: return @"Read-only on this system";
            case VDTApplySkipCapabilityMissing: case VDTApplySkipBackendMissing: return @"Write backend unavailable";
            case VDTApplySkipRestorePending: return @"Restoration pending";
            case VDTApplySkipIdentity: return @"Process identity not verified";
            case VDTApplySkipReadbackFailed: return @"Readback failed";
            case VDTApplySkipConflict: return @"Changed; not overwritten";
            case VDTApplySkipNoWrite:
                return [overall isEqual:@"write-disabled"] ? @"Resource rules are paused" : @"No resource write requested";
            default: break;
        }
    }
    if ([overall isEqual:@"write-disabled"]) return @"Resource rules are paused";
    if ([overall isEqual:@"gone"]) return @"Previous process exited";
    // No per-side fields + unsupported is a backend-wide refusal, not a
    // policy skip. In particular skip=Unsupported above must not reach here.
    if ([overall isEqual:@"unsupported"] && !perSide && !skip) return @"Write backend unavailable";
    if ([overall isEqual:@"pending"]) return @"Resource work pending";
    if ([overall isEqual:@"no-write"]) return @"No resource write requested";
    // A sibling's aggregate success/conflict cannot supply this side's result.
    return @"Side result not recorded";
}
static NSString *VDTCheckTone(NSString *state) {
    if ([@[@"Nice state applied", @"Nice state restored", @"Rule readback matched", @"Recorded values restored"] containsObject:state])
        return @"ok";
    if ([@[@"Changed; not overwritten", @"Rule not applied", @"Resource journal unavailable", @"Readback failed",
        @"Resource write not verified", @"Write backend unavailable", @"Nice state conflict", @"Nice state read failed",
        @"Nice state write failed", @"Nice state verify failed", @"Nice state store failed", @"Nice state invalid",
        @"Nice receipt exceeds size limit", @"Nice receipt unavailable"] containsObject:state])
        return @"warning";
    return @"neutral";
}
static NSDictionary *VDTCheckResourceReceipt(NSDictionary *receipt, NSString *side) {
    NSDictionary *sides = VDTCheckDictionary(receipt[@"sideReceipts"]);
    // An explicitly malformed new envelope is unknown, never a success fallback.
    NSMutableDictionary *selected = receipt[@"sideReceipts"]
        ? ([VDTCheckDictionary(sides[side]) mutableCopy] ?: [NSMutableDictionary dictionary])
        : [receipt mutableCopy];
    if (!selected) return nil;
    for (NSString *key in @[@"multipleInstances", @"instanceCount", @"storeError"])
        if (receipt[key]) selected[key] = receipt[key];
    if ([receipt[@"state"] isEqual:@"store-error"]) selected[@"state"] = @"store-error";
    id checked = selected[[side stringByAppendingString:@"CheckedAt"]];
    if (checked) selected[@"checkedAt"] = checked;
    return selected;
}
static NSDictionary *VDTCheckField(NSString *identifier, NSString *label, NSString *value,
    NSString *tone, VDTCheckLocalizer localize) {
    return @{@"id": identifier, @"label": VDTCheckText(localize, label),
        @"value": value ?: VDTCheckText(localize, @"Not recorded"), @"tone": tone ?: @"plain"};
}
static NSString *VDTCheckNumber(id value) { return VDTCheckInteger(value).stringValue; }
static void VDTCheckDiagnostic(NSMutableArray *fields, NSString *key, NSString *label,
    NSString *value, VDTCheckLocalizer localize) {
    [fields addObject:VDTCheckField(key, label, value, nil, localize)];
}
static BOOL VDTCheckRuleMatches(NSDictionary *receipt, NSDictionary *rule) {
    if (!receipt[@"checkedRule"]) return YES; // Legacy rows remain explicitly historical.
    NSDictionary *checked = VDTCheckDictionary(receipt[@"checkedRule"]);
    if (!checked || !rule) return NO;
    for (NSString *key in @[@"value", @"valid", @"enabled", @"requestedEnabled", @"revision",
        @"present", @"sourceType", @"sourceIdentifier", @"sourceRevision", @"containingAppIdentifier"])
        if (![(checked[key] ?: NSNull.null) isEqual:(rule[key] ?: NSNull.null)]) return NO;
    return YES;
}
static NSDictionary *VDTCheckRow(NSString *title, NSDictionary *rule, NSDictionary *receipt,
    NSString *side, BOOL nice, VDTCheckLocalizer localize) {
    BOOL memory = [side isEqual:@"memory"];
    if (!nice) receipt = VDTCheckResourceReceipt(receipt, side);
    NSString *stateKey = nice ? VDTCheckNiceState(receipt) : VDTCheckResourceState(receipt, side);
    NSString *target = VDTCheckTarget(rule, memory, nice, localize);
    NSNumber *count = VDTCheckInteger(receipt[nice ? @"targetCount" : @"instanceCount"]);
    NSNumber *outcomeCount = nice ? VDTCheckInteger(receipt[@"outcomeCount"]) : nil;
    BOOL multiple = nice ? (count.longLongValue > 1 || outcomeCount.longLongValue > 1)
        : (VDTCheckTrue(receipt[@"multipleInstances"]) || count.longLongValue > 1);
    // Only historical observed is accepted. A future current observation has its
    // own timestamp and must never inherit this receipt's checkedAt.
    id rawObserved = nice ? receipt[@"observed"] : receipt[[side stringByAppendingString:@"Observed"]];
    if (nice && multiple) rawObserved = nil;
    BOOL hasObserved = memory ? VDTCheckPair(rawObserved) != nil : VDTCheckInteger(rawObserved) != nil;
    NSString *observed = memory ? VDTCheckMemoryReadback(rawObserved, localize)
        : (VDTCheckNumber(rawObserved) ?: VDTCheckText(localize, @"Not recorded"));
    NSString *evidence = VDTCheckString(receipt[nice ? @"evidence" : [side stringByAppendingString:@"Evidence"]]);
    if ([stateKey isEqual:@"Nice state applied"] || [stateKey isEqual:@"Rule readback matched"]) {
        if (!hasObserved) stateKey = @"Reported applied; readback missing";
        else if ([evidence isEqual:@"matched-without-set"]) stateKey = @"Readback matches; no write needed";
        else if ([evidence isEqual:@"written-verified"]) stateKey = @"Write readback confirmed";
    } else if (([stateKey isEqual:@"Nice state restored"] || [stateKey isEqual:@"Recorded values restored"]) && !hasObserved)
        stateKey = @"Reported restored; readback missing";
    if (nice && !VDTCheckRuleMatches(receipt, rule)) stateKey = @"Receipt belongs to earlier settings";
    NSString *state = VDTCheckText(localize, stateKey);
    NSString *tone = VDTCheckTone(stateKey);
    if ([stateKey isEqual:@"Readback matches; no write needed"] || [stateKey isEqual:@"Write readback confirmed"]) tone = @"ok";
    // Short display only. Preserve the evidence/diagnostics model below; a
    // missing result must never turn into success merely to shorten the UI.
    NSString *compactState = @"Not confirmed", *compactTone = @"neutral";
    if ([tone isEqual:@"ok"]) {
        BOOL restored = [stateKey isEqual:@"Nice state restored"] || [stateKey isEqual:@"Recorded values restored"];
        compactState = multiple ? @"Partly confirmed" : (restored ? @"Restored" : @"Applied");
        compactTone = multiple ? @"neutral" : @"ok";
    } else if ([tone isEqual:@"warning"] || [@[@"Read-only on this system", @"Process identity not verified",
        @"Nice state protected", @"Resource rules are paused", @"Nice state paused"] containsObject:stateKey]) {
        compactState = @"Not applied"; compactTone = @"warning";
    } else if ([@[@"Nice state pending", @"Resource work pending", @"Restoration pending"] containsObject:stateKey]) {
        compactState = @"Pending";
    } else if ([stateKey isEqual:@"Nice state disabled"] || ((!receipt || [stateKey isEqual:@"No resource write requested"]) &&
        (!rule || VDTCheckFalse(rule[nice ? @"requestedEnabled" : @"enabled"])))) {
        compactState = @"Not enabled";
    }
    NSString *timestamp = VDTCheckTime(receipt, nice, localize);
    NSString *scope = VDTCheckText(localize, @"Instance scope not recorded");
    if (multiple) scope = VDTCheckText(localize, nice ? @"Multiple instances; individual readbacks unavailable"
        : @"Multiple instances; selected instance only");
    else if (count && count.longLongValue == 1) scope = VDTCheckText(localize, @"One recorded instance");
    else if (count && count.longLongValue == 0) scope = VDTCheckText(localize, @"No verified running instance");
    else if (!nice && VDTCheckInteger(receipt[@"pid"])) scope = VDTCheckText(localize, @"Selected instance only; total not recorded");
    if (!nice && multiple) scope = [scope stringByAppendingFormat:@"\n%@", VDTCheckText(localize,
        @"Other instance results were not retained in this receipt; this is not an all-instance success claim.")];
    NSMutableArray *summary = [NSMutableArray array];
    [summary addObject:[NSString stringWithFormat:VDTCheckText(localize,
        memory ? @"Saved target (active / inactive): %@" : @"Saved target: %@"), target]];
    [summary addObject:[NSString stringWithFormat:VDTCheckText(localize, @"Last read back: %@"), observed]];
    NSString *observedAt = hasObserved ? VDTCheckDate(receipt[nice ? @"observedAt" : [side stringByAppendingString:@"ObservedAt"]]) : nil;
    NSMutableArray *core = [NSMutableArray arrayWithArray:@[
        VDTCheckField(@"state", @"Receipt status", state, tone, localize),
        VDTCheckField(@"target", memory ? @"Saved target (active / inactive)" : @"Saved target", target, nil, localize),
        VDTCheckField(@"observed", memory ? @"Last readback (active / inactive)" : @"Last readback", observed, nil, localize),
        VDTCheckField(@"readTime", @"Readback recorded at", observedAt, nil, localize),
        VDTCheckField(@"checkTime", @"Last check", VDTCheckDate(VDTCheckTimeValue(receipt, nice)), nil, localize),
        VDTCheckField(@"scope", @"Recorded scope", scope, nil, localize)
    ]];
    if ([stateKey isEqual:@"Rule not applied"])
        [core addObject:VDTCheckField(@"policyNote", @"Interpretation",
            VDTCheckText(localize, @"This rule was rejected. A policy skip is not a system-write failure."), @"plain", localize)];
    // Stable IDs/counts let native controllers update rows in place, including
    // missing fields. Raw diagnostics never enter the summary or core arrays.
    NSMutableArray *diagnostics = [NSMutableArray array];
    VDTCheckDiagnostic(diagnostics, @"code", @"Receipt code", VDTCheckString(receipt[nice ? @"state" : side]), localize);
    VDTCheckDiagnostic(diagnostics, @"evidence", @"Evidence code", evidence, localize);
    VDTCheckDiagnostic(diagnostics, @"pid", @"Selected PID", VDTCheckNumber(receipt[@"pid"]), localize);
    NSString *seconds = VDTCheckNumber(receipt[@"startSeconds"]), *micros = VDTCheckNumber(receipt[@"startMicroseconds"]);
    VDTCheckDiagnostic(diagnostics, @"instance", @"Process start token",
        seconds && micros ? [NSString stringWithFormat:@"%@:%@", seconds, micros] : nil, localize);
    if (nice) {
        VDTCheckDiagnostic(diagnostics, @"original", @"Original", VDTCheckNumber(receipt[@"original"]), localize);
        VDTCheckDiagnostic(diagnostics, @"errno", @"errno", VDTCheckNumber(receipt[@"error"]), localize);
        VDTCheckDiagnostic(diagnostics, @"receiptTime", @"Receipt saved at", VDTCheckDate(receipt[@"receiptUpdatedAt"]), localize);
        VDTCheckDiagnostic(diagnostics, @"pending", @"Pending targets", VDTCheckNumber(receipt[@"pendingCount"]), localize);
        VDTCheckDiagnostic(diagnostics, @"count", @"Recorded instances", VDTCheckNumber(receipt[@"targetCount"]), localize);
        VDTCheckDiagnostic(diagnostics, @"outcomes", @"Recorded outcomes", VDTCheckNumber(receipt[@"outcomeCount"]), localize);
        VDTCheckDiagnostic(diagnostics, @"writeCalls", @"Write callback calls", VDTCheckNumber(receipt[@"writeCalls"]), localize);
        VDTCheckDiagnostic(diagnostics, @"retry", @"Bounded retry pending",
            VDTCheckTrue(receipt[@"retryPending"]) ? VDTCheckText(localize, @"Yes")
            : VDTCheckFalse(receipt[@"retryPending"]) ? VDTCheckText(localize, @"No") : nil, localize);
        NSDictionary *checked = VDTCheckDictionary(receipt[@"checkedRule"]);
        VDTCheckDiagnostic(diagnostics, @"checkedTarget", @"Target at check", VDTCheckNumber(checked[@"value"]), localize);
        VDTCheckDiagnostic(diagnostics, @"revision", @"Rule revision at check", VDTCheckString(checked[@"revision"]), localize);
    } else {
        VDTCheckDiagnostic(diagnostics, @"planSkip", @"Planning skip code",
            VDTCheckNumber(receipt[[side stringByAppendingString:@"PlanSkip"]])
            ?: VDTCheckNumber(receipt[[side stringByAppendingString:@"Skip"]]), localize);
        VDTCheckDiagnostic(diagnostics, @"executionSkip", @"Execution skip code",
            VDTCheckNumber(receipt[[side stringByAppendingString:@"ExecutionSkip"]]), localize);
        VDTCheckDiagnostic(diagnostics, @"outcome", @"Execution outcome code",
            VDTCheckNumber(receipt[[side stringByAppendingString:@"ExecutionOutcome"]]), localize);
        id ran = receipt[[side stringByAppendingString:@"ExecutorRan"]];
        VDTCheckDiagnostic(diagnostics, @"executor", @"Entered write executor",
            VDTCheckTrue(ran) ? VDTCheckText(localize, @"Yes") : VDTCheckFalse(ran) ? VDTCheckText(localize, @"No") : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"errno", @"errno", VDTCheckNumber(receipt[[side stringByAppendingString:@"Error"]]), localize);
        VDTCheckDiagnostic(diagnostics, @"storeError", @"Storage errno", VDTCheckNumber(receipt[@"storeError"]), localize);
        VDTCheckDiagnostic(diagnostics, @"count", @"Recorded instances", VDTCheckNumber(receipt[@"instanceCount"]), localize);
        id executionTarget = receipt[[side stringByAppendingString:@"Target"]];
        VDTCheckDiagnostic(diagnostics, @"checkedTarget", @"Operation target",
            memory ? (VDTCheckPair(executionTarget) ? [executionTarget description] : nil) : VDTCheckNumber(executionTarget), localize);
        VDTCheckDiagnostic(diagnostics, @"action", @"Operation code", VDTCheckString(receipt[[side stringByAppendingString:@"Action"]]), localize);
        NSArray *pair = memory ? VDTCheckPair(rawObserved) : nil;
        VDTCheckDiagnostic(diagnostics, @"rawReadback", @"Raw readback", pair
            ? [NSString stringWithFormat:@"[%@, %@, %@, %@]", pair[0], pair[1], pair[2], pair[3]] : VDTCheckNumber(rawObserved), localize);
        VDTCheckDiagnostic(diagnostics, @"readStart", @"Read window started at",
            hasObserved ? VDTCheckDate(receipt[[side stringByAppendingString:@"ReadStartedAt"]]) : nil, localize);
    }
    return @{@"title": VDTCheckText(localize, title), @"state": state, @"tone": tone,
        @"compactState": VDTCheckText(localize, compactState), @"compactTone": compactTone,
        @"summary": [summary componentsJoinedByString:@"\n"], @"timestamp": timestamp, @"scope": scope,
        @"coreFields": core, @"diagnosticFields": diagnostics};
}
NSArray<NSDictionary *> *VDTCheckResultModels(NSDictionary *niceRule, NSDictionary *niceReceipt,
    NSDictionary *memoryRule, NSDictionary *jetsamRule, NSDictionary *resourceReceipt,
    VDTCheckLocalizer localize) {
    niceRule = VDTCheckDictionary(niceRule); niceReceipt = VDTCheckDictionary(niceReceipt);
    memoryRule = VDTCheckDictionary(memoryRule); jetsamRule = VDTCheckDictionary(jetsamRule);
    resourceReceipt = VDTCheckDictionary(resourceReceipt);
    return @[VDTCheckRow(@"nice", niceRule, niceReceipt, @"nice", YES, localize),
        VDTCheckRow(@"Memory", memoryRule, resourceReceipt, @"memory", NO, localize),
        VDTCheckRow(@"Reclaim priority", jetsamRule, resourceReceipt, @"priority", NO, localize)];
}
