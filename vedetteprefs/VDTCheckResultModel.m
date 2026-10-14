// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultModel.h"
#import <CoreFoundation/CoreFoundation.h>
#include "../VDTResourceApply.h"
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
static NSString *VDTCheckTime(NSDictionary *receipt, BOOL nice, VDTCheckLocalizer localize) {
    id raw = nice ? (receipt[@"oldestCheckedAt"] ?: receipt[@"checkedAt"]) : receipt[@"checkedAt"];
    if ([raw isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)raw) != CFBooleanGetTypeID()) {
        double seconds = [raw doubleValue];
        if (isfinite(seconds) && seconds > 0 && seconds < 253402300800.0) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds];
            NSString *stamp = [NSDateFormatter localizedStringFromDate:date
                dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
            return [NSString stringWithFormat:VDTCheckText(localize, @"Last check: %@"), stamp];
        }
    }
    return VDTCheckText(localize, @"Check time not recorded");
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
    NSNumber *skip = VDTCheckInteger(receipt[[side stringByAppendingString:@"Skip"]]);
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
        @"Nice state write failed", @"Nice state verify failed", @"Nice state store failed", @"Nice state invalid"] containsObject:state])
        return @"warning";
    return @"neutral";
}
static void VDTCheckAddNumber(NSMutableArray *lines, NSDictionary *receipt, NSString *field,
    NSString *key, VDTCheckLocalizer localize) {
    NSNumber *number = VDTCheckInteger(receipt[field]);
    if (number) [lines addObject:[NSString stringWithFormat:VDTCheckText(localize, key), number]];
}
static NSDictionary *VDTCheckRow(NSString *title, NSDictionary *rule, NSDictionary *receipt,
    NSString *side, BOOL nice, VDTCheckLocalizer localize) {
    BOOL memory = [side isEqual:@"memory"];
    NSString *stateKey = nice ? VDTCheckNiceState(receipt) : VDTCheckResourceState(receipt, side);
    NSString *state = VDTCheckText(localize, stateKey);
    NSString *target = VDTCheckTarget(rule, memory, nice, localize);
    NSNumber *count = nice ? VDTCheckInteger(receipt[@"targetCount"]) : nil;
    BOOL multiple = nice ? count.longLongValue > 1 : VDTCheckTrue(receipt[@"multipleInstances"]);
    id rawObserved = nice ? (receipt[@"observed"] ?: receipt[@"current"]) : receipt[[side stringByAppendingString:@"Observed"]];
    NSString *observed = nil;
    if (memory) observed = VDTCheckMemoryReadback(rawObserved, localize);
    else {
        NSNumber *number = VDTCheckInteger(rawObserved);
        if (nice && multiple) number = nil; // aggregate nice receipts are not per-instance readbacks
        observed = number ? number.stringValue : VDTCheckText(localize, @"Not recorded");
    }
    NSString *timestamp = VDTCheckTime(receipt, nice, localize);
    NSMutableArray *summary = [NSMutableArray array];
    if (memory) [summary addObject:VDTCheckText(localize, @"Active / Inactive")];
    [summary addObject:[NSString stringWithFormat:VDTCheckText(localize, @"Saved target: %@"), target]];
    [summary addObject:[NSString stringWithFormat:VDTCheckText(localize, @"Last read back: %@"), observed]];
    if (multiple) [summary addObject:VDTCheckText(localize, nice ? @"Multiple instances; individual readbacks unavailable" :
        @"Multiple instances; selected instance only")];
    NSMutableArray *details = [summary mutableCopy];
    [details addObject:timestamp];
    NSString *rawState = VDTCheckString(receipt[nice ? @"state" : side]);
    if (rawState) [details addObject:[NSString stringWithFormat:VDTCheckText(localize, @"Receipt code: %@"), rawState]];
    if (nice) {
        VDTCheckAddNumber(details, receipt, @"original", @"Original: %@", localize);
        VDTCheckAddNumber(details, receipt, @"error", @"errno: %@", localize);
        VDTCheckAddNumber(details, receipt, @"pendingCount", @"Pending targets: %@", localize);
        VDTCheckAddNumber(details, receipt, @"targetCount", @"Recorded instances: %@", localize);
        if (VDTCheckTrue(receipt[@"retryPending"])) [details addObject:VDTCheckText(localize, @"Bounded retry pending")];
    } else {
        VDTCheckAddNumber(details, receipt, @"pid", @"Selected PID: %@", localize);
        VDTCheckAddNumber(details, receipt, [side stringByAppendingString:@"Skip"], @"Skip code: %@", localize);
        VDTCheckAddNumber(details, receipt, @"storeError", @"errno: %@", localize);
        NSArray *pair = memory ? VDTCheckPair(rawObserved) : nil;
        if (pair) {
            NSString *raw = [NSString stringWithFormat:@"[%@, %@, %@, %@]", pair[0], pair[1], pair[2], pair[3]];
            [details addObject:[NSString stringWithFormat:VDTCheckText(localize, @"Raw memory readback: %@"), raw]];
        }
        if ([stateKey isEqual:@"Rule not applied"])
            [details addObject:VDTCheckText(localize, @"This rule was rejected. A policy skip is not a system-write failure.")];
        if (multiple) [details addObject:VDTCheckText(localize,
            @"Other instance results were not retained in this receipt; this is not an all-instance success claim.")];
    }
    [details addObject:VDTCheckText(localize, @"Historical receipt, not live monitoring. Refresh only reloads saved results.")];
    return @{@"title": VDTCheckText(localize, title), @"state": state, @"tone": VDTCheckTone(stateKey),
        @"summary": [summary componentsJoinedByString:@"\n"], @"timestamp": timestamp,
        @"details": [details componentsJoinedByString:@"\n"]};
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
