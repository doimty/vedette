// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultModel.h"
#import <CoreFoundation/CoreFoundation.h>
#include "../VDTResourceApply.h"
#include "../VDTResourceSummary.h"
#include <errno.h>
#include <limits.h>
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
static NSNumber *VDTCheckBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? value : nil;
}
static BOOL VDTCheckTrue(id value) { return [VDTCheckBoolean(value) boolValue]; }
static BOOL VDTCheckFalse(id value) { return VDTCheckBoolean(value) && ![value boolValue]; }
static NSString *VDTCheckText(VDTCheckLocalizer localize, NSString *key) {
    return localize ? (localize(key) ?: key) : key;
}
static BOOL VDTCheckEpoch(id raw) {
    if (![raw isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) return NO;
    double seconds = [raw doubleValue];
    return isfinite(seconds) && seconds > 0 && seconds < 253402300800.0;
}
static NSString *VDTCheckDate(id raw) {
    return VDTCheckEpoch(raw)
        ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[raw doubleValue]]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle] : nil;
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
static BOOL VDTCheckSettingsUnavailable(NSDictionary *rule, NSDictionary *receipt) {
    return (rule[@"settingsAvailable"] && !VDTCheckTrue(rule[@"settingsAvailable"])) ||
        (receipt[@"settingsAvailable"] && !VDTCheckTrue(receipt[@"settingsAvailable"]));
}
static BOOL VDTCheckSettingsInvalid(NSDictionary *rule, NSDictionary *receipt, BOOL memory, BOOL nice) {
    if ((rule[@"configurationValid"] && !VDTCheckTrue(rule[@"configurationValid"])) ||
        (receipt[@"configurationValid"] && !VDTCheckTrue(receipt[@"configurationValid"]))) return YES;
    if (!rule || VDTCheckFalse(rule[@"present"])) return NO; // Known absence is different from unreadable settings.
    id enabled = rule[nice ? @"requestedEnabled" : @"enabled"];
    if (VDTCheckFalse(enabled)) return NO;
    if (!VDTCheckTrue(enabled)) return YES;
    if (nice) {
        NSNumber *value = VDTCheckInteger(rule[@"value"]);
        return !VDTCheckTrue(rule[@"valid"]) || !value || value.longLongValue < -20 || value.longLongValue > 20;
    }
    if (!memory) {
        NSNumber *value = VDTCheckInteger(rule[@"priority"]);
        return !value || value.longLongValue > INT32_MAX;
    }
    NSNumber *active = VDTCheckInteger(rule[@"active"]), *inactive = VDTCheckInteger(rule[@"inactive"]);
    if (!active || !inactive) return YES;
    return !((active.longLongValue == -1 && inactive.longLongValue == -1) ||
        (active.longLongValue == 0 && inactive.longLongValue == 0) ||
        (active.longLongValue > 0 && active.longLongValue <= INT32_MAX &&
         inactive.longLongValue > 0 && inactive.longLongValue <= INT32_MAX));
}
static NSString *VDTCheckTarget(NSDictionary *rule, BOOL memory, BOOL nice, VDTCheckLocalizer localize) {
    if (VDTCheckSettingsUnavailable(rule, nil)) return VDTCheckText(localize, @"Saved settings unavailable");
    if (rule[@"configurationValid"] && !VDTCheckTrue(rule[@"configurationValid"]))
        return VDTCheckText(localize, @"Incomplete settings");
    if (!rule || VDTCheckFalse(rule[@"present"])) return VDTCheckText(localize, @"Not configured");
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
    if ([@[@"Nice state applied", @"Nice state restored", @"Rule readback matched", @"Recorded values restored",
        @"Readback matches; no write needed", @"Write readback confirmed"] containsObject:state])
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
    NSDictionary *sideReceipt = VDTCheckDictionary(sides[side]);
    // Keep the worst side's real error/readback, but the aggregate's batch and
    // counts. An explicitly malformed side envelope never falls back to success.
    NSMutableDictionary *selected = receipt[@"sideReceipts"]
        ? ([sideReceipt mutableCopy] ?: [NSMutableDictionary dictionary]) : [receipt mutableCopy];
    if (!selected) return nil;
    if (receipt[@"sideReceipts"] && !sideReceipt) selected[@"sideEnvelopeInvalid"] = @YES;
    for (NSString *key in @[@"multipleInstances", @"instanceCount", @"storeError", @"summaries", @"checkBatch",
        @"historicalOnly", @"latestCheck", @"configurationValid", @"settingsAvailable", @"paused"])
        if (receipt[key]) selected[key] = receipt[key];
    if ([receipt[@"state"] isEqual:@"store-error"]) selected[@"state"] = @"store-error";
    if ([receipt[@"state"] isEqual:@"configuration-invalid"]) selected[@"configurationValid"] = @NO;
    id checked = selected[[side stringByAppendingString:@"CheckedAt"]];
    if (checked) selected[@"checkedAt"] = checked;
    // Never copy an aggregate or latest-attempt timestamp over a side readback.
    return selected;
}
typedef struct {
    BOOL present;
    BOOL valid;
    VDTResourceSummaryCounts counts;
    VDTResourceSummaryState state;
} VDTCheckSummary;
static NSDictionary *VDTCheckLatestCheck(NSDictionary *receipt) {
    NSDictionary *latest = VDTCheckDictionary(receipt[@"latestCheck"]);
    NSNumber *version = VDTCheckInteger(latest[@"version"]), *batch = VDTCheckInteger(latest[@"batch"]);
    NSNumber *error = VDTCheckInteger(latest[@"error"]);
    if (!version || version.longLongValue != 1 || !batch || batch.longLongValue <= 0 ||
        !VDTCheckBoolean(latest[@"enumerationComplete"]) || !error || error.longLongValue < 0 ||
        error.longLongValue > INT_MAX || !VDTCheckEpoch(latest[@"attemptedAt"])) return nil;
    return latest;
}
static VDTCheckSummary VDTCheckResourceSummary(NSDictionary *receipt, NSString *side) {
    VDTCheckSummary result = {0}; result.state = VDTResourceSummaryInvalid;
    result.present = receipt[@"summaries"] || receipt[@"checkBatch"] || receipt[@"latestCheck"] ||
        receipt[@"historicalOnly"] || receipt[@"sideEnvelopeInvalid"];
    if (!result.present || VDTCheckTrue(receipt[@"sideEnvelopeInvalid"]) ||
        (receipt[@"historicalOnly"] && !VDTCheckFalse(receipt[@"historicalOnly"])) ||
        (receipt[@"configurationValid"] && !VDTCheckTrue(receipt[@"configurationValid"]))) return result;
    NSDictionary *summaries = VDTCheckDictionary(receipt[@"summaries"]);
    NSDictionary *summary = VDTCheckDictionary(summaries[side]);
    NSDictionary *latest = VDTCheckLatestCheck(receipt);
    NSNumber *version = VDTCheckInteger(summary[@"version"]), *batch = VDTCheckInteger(summary[@"batch"]);
    NSNumber *rowBatch = VDTCheckInteger(receipt[@"checkBatch"]);
    if (!summary || !latest || !version || version.longLongValue != 1 || !batch || batch.longLongValue <= 0 ||
        !rowBatch || rowBatch.longLongValue <= 0 || ![batch isEqual:rowBatch] || ![batch isEqual:latest[@"batch"]] ||
        ![VDTCheckString(summary[@"scope"]) isEqual:@"identified-targets"] ||
        !VDTCheckBoolean(summary[@"enumerationComplete"]) ||
        ![summary[@"enumerationComplete"] isEqual:latest[@"enumerationComplete"]]) return result;
    // No numeric/string/Boolean coercion or inferred missing zeros. Every count
    // belongs to this one batch and must fit the portable helper's bounded sum.
    for (NSString *key in @[@"total", @"applied", @"restored", @"failed", @"pending", @"unknown", @"disabled"]) {
        NSNumber *count = VDTCheckInteger(summary[key]);
        if (!count || count.longLongValue < 0 || count.longLongValue > 65536) return result;
    }
    result.counts = (VDTResourceSummaryCounts){[summary[@"total"] unsignedIntValue], [summary[@"applied"] unsignedIntValue],
        [summary[@"restored"] unsignedIntValue], [summary[@"failed"] unsignedIntValue], [summary[@"pending"] unsignedIntValue],
        [summary[@"unknown"] unsignedIntValue], [summary[@"disabled"] unsignedIntValue]};
    if (!VDTResourceSummaryCountsValid(result.counts)) return result;
    result.state = VDTResourceSummaryDecide(result.counts);
    result.valid = result.state != VDTResourceSummaryInvalid;
    return result;
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
static NSString *VDTCheckInterpretation(NSString *stateKey, BOOL unavailable, BOOL invalid,
    BOOL historical, BOOL localPending, BOOL multiple, VDTCheckSummary summary, VDTCheckLocalizer localize) {
    NSString *key = @"A saved receipt is not live monitoring. Missing evidence cannot confirm an applied value.";
    if (unavailable) key = @"Saved settings could not be read. No enabled or successful state can be inferred.";
    else if (invalid) key = @"Saved settings are incomplete or invalid. Recorded readbacks are kept as history.";
    else if (localPending) key = @"A check was requested from this screen. Earlier readbacks and times remain unchanged until a new result is recorded.";
    else if (historical) key = @"This is an earlier recorded result. The latest attempt did not check this instance.";
    else if (summary.present && !summary.valid)
        key = @"Coverage is missing, malformed, or belongs to another check. Earlier readbacks are shown without a new success claim.";
    else if ([stateKey isEqual:@"Rule not applied"])
        key = @"This rule was rejected. A policy skip is not a system-write failure.";
    else if ([@[@"Resource rules are paused", @"Nice state paused", @"Nice state disabled", @"No resource write requested"] containsObject:stateKey])
        key = @"This rule is off or paused. That is not a write failure.";
    else if (summary.valid) {
        switch (summary.state) {
            case VDTResourceSummaryConfirmed:
                key = @"Every identified instance in this check was confirmed. This does not cover unidentified processes or provide live monitoring."; break;
            case VDTResourceSummaryRestored:
                key = @"Every identified instance in this check was restored to its recorded value. This is not live monitoring."; break;
            case VDTResourceSummaryPartial:
                key = @"Only some identified instances were confirmed. The counts keep not-applied, pending, and unknown results separate."; break;
            case VDTResourceSummaryFailed:
                key = @"No identified instance was confirmed, and at least one was explicitly not applied."; break;
            case VDTResourceSummaryPending:
                key = @"The identified instances have pending work. Pending is not a confirmed result."; break;
            case VDTResourceSummaryDisabled:
                key = @"This rule is off or paused. That is not a write failure."; break;
            case VDTResourceSummaryNoResult:
                key = @"No identified instance was checked. An empty result is not a success."; break;
            default: key = @"This check did not establish confirmation for the identified instances."; break;
        }
    } else if (multiple && [VDTCheckTone(stateKey) isEqual:@"ok"])
        key = @"Only the selected instance has a confirmed readback. Results for other instances are not established.";
    else if ([@[@"Nice state applied", @"Rule readback matched", @"Readback matches; no write needed", @"Write readback confirmed"] containsObject:stateKey])
        key = @"The recorded readback matched for this instance at the recorded time; it is not a live value.";
    else if ([@[@"Nice state restored", @"Recorded values restored"] containsObject:stateKey])
        key = @"The recorded readback confirmed restoration for this instance; it is not a live value.";
    return VDTCheckText(localize, key);
}
static NSDictionary *VDTCheckRow(NSString *title, NSDictionary *rule, NSDictionary *receipt,
    NSString *side, BOOL nice, VDTCheckLocalizer localize) {
    BOOL memory = [side isEqual:@"memory"];
    if (!nice) receipt = VDTCheckResourceReceipt(receipt, side);
    BOOL unavailable = VDTCheckSettingsUnavailable(rule, receipt);
    BOOL invalid = VDTCheckSettingsInvalid(rule, receipt, memory, nice);
    BOOL historical = VDTCheckTrue(receipt[@"historicalOnly"]);
    BOOL localPending = nice && VDTCheckTrue(receipt[@"localPending"]);
    VDTCheckSummary resourceSummary = nice ? (VDTCheckSummary){0} : VDTCheckResourceSummary(receipt, side);
    NSDictionary *latest = nice ? nil : VDTCheckLatestCheck(receipt);
    NSString *stateKey = nice ? VDTCheckNiceState(receipt) : VDTCheckResourceState(receipt, side);
    NSString *target = unavailable ? VDTCheckText(localize, @"Saved settings unavailable")
        : VDTCheckTarget(rule, memory, nice, localize);
    NSNumber *count = VDTCheckInteger(receipt[nice ? @"targetCount" : @"instanceCount"]);
    NSNumber *outcomeCount = nice ? VDTCheckInteger(receipt[@"outcomeCount"]) : nil;
    BOOL multiple = nice ? (count.longLongValue > 1 || outcomeCount.longLongValue > 1)
        : (VDTCheckTrue(receipt[@"multipleInstances"]) || count.longLongValue > 1);
    // Only historical observed is accepted. A future current observation has its
    // own timestamp and must never inherit this receipt's checkedAt. Bad summary
    // evidence changes coverage, not the retained side's real historical readback.
    id rawObserved = nice ? receipt[@"observed"] : receipt[[side stringByAppendingString:@"Observed"]];
    if (nice && multiple) rawObserved = nil; // Nice aggregate receipts have no individual readback.
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
    if (unavailable) stateKey = @"Saved settings unavailable";
    else if (invalid) stateKey = @"Incomplete settings";
    NSString *state = VDTCheckText(localize, stateKey);
    NSString *tone = VDTCheckTone(stateKey);
    BOOL paused = [stateKey isEqual:@"Resource rules are paused"] || [stateKey isEqual:@"Nice state paused"] ||
        VDTCheckTrue(receipt[@"paused"]) || VDTCheckFalse(rule[@"globallyEnabled"]);
    BOOL off = VDTCheckFalse(rule[nice ? @"requestedEnabled" : @"enabled"]) || [stateKey isEqual:@"Nice state disabled"];
    BOOL restored = [stateKey isEqual:@"Nice state restored"] || [stateKey isEqual:@"Recorded values restored"];
    BOOL pending = [@[@"Nice state pending", @"Resource work pending", @"Restoration pending"] containsObject:stateKey];
    // Compact state describes the validated batch, not the selected worst side's
    // diagnostic reason. A scope qualifier alone is never a partial failure.
    NSString *compactState = @"Not confirmed", *compactTone = @"neutral";
    NSString *compactDisplay = nil;
    if (unavailable) compactState = @"Saved settings unavailable";
    else if (invalid) { /* Unknown settings cannot confirm any current result. */ }
    else if (localPending) compactState = @"Checking…";
    else if (resourceSummary.present) {
        if (resourceSummary.valid && !historical) {
            VDTResourceSummaryCounts counts = resourceSummary.counts;
            NSNumber *confirmed = @(VDTResourceSummaryConfirmedCount(counts)), *total = @(counts.total);
            switch (resourceSummary.state) {
                case VDTResourceSummaryConfirmed:
                    compactState = @"Confirmed"; compactTone = @"ok";
                    if (counts.total > 1) compactDisplay = [NSString stringWithFormat:VDTCheckText(localize, @"Confirmed (%@/%@)"), confirmed, total];
                    break;
                case VDTResourceSummaryRestored: compactState = @"Restored"; compactTone = @"ok"; break;
                case VDTResourceSummaryPartial:
                    compactDisplay = [NSString stringWithFormat:VDTCheckText(localize, @"Partly confirmed (%@/%@)"), confirmed, total];
                    compactTone = counts.failed ? @"warning" : @"neutral"; break;
                case VDTResourceSummaryFailed: compactState = @"Not applied"; compactTone = @"warning"; break;
                case VDTResourceSummaryPending: compactState = @"Pending"; break;
                case VDTResourceSummaryDisabled:
                    compactState = paused ? @"Paused" : off ? @"Not enabled" : memory && VDTCheckTrue(rule[@"enabled"]) &&
                        [VDTCheckInteger(rule[@"active"]) longLongValue] == 0 && [VDTCheckInteger(rule[@"inactive"]) longLongValue] == 0
                        ? @"No restoration needed" : @"No write requested"; break;
                default: break; // Unknown, empty, and invalid are never success.
            }
        }
    } else if (paused && !restored && !pending) compactState = @"Paused";
    else if (off && !restored && !pending) compactState = @"Not enabled";
    else if ([tone isEqual:@"ok"]) {
        compactState = multiple ? @"Selected instance confirmed" : (restored ? @"Restored" : @"Confirmed");
        compactTone = @"ok";
    } else if (pending) compactState = @"Pending";
    else if ([tone isEqual:@"warning"] || [@[@"Read-only on this system", @"Process identity not verified", @"Nice state protected"] containsObject:stateKey]) {
        compactState = @"Not applied"; compactTone = @"warning";
    } else if ([stateKey isEqual:@"No resource write requested"]) compactState = @"No write requested";
    if (!compactDisplay) compactDisplay = VDTCheckText(localize, compactState);
    NSString *timestamp = VDTCheckTime(receipt, nice, localize);
    NSString *scope = VDTCheckText(localize, @"Instance scope not recorded");
    if (resourceSummary.valid && !unavailable && !invalid) scope = VDTCheckText(localize, @"Identified instances in this check only");
    else if (multiple) scope = VDTCheckText(localize, nice ? @"Multiple instances; individual readbacks unavailable"
        : @"Multiple instances; selected instance only");
    else if (count && count.longLongValue == 1) scope = VDTCheckText(localize, @"One recorded instance");
    else if (count && count.longLongValue == 0) scope = VDTCheckText(localize, @"No verified running instance");
    else if (!nice && VDTCheckInteger(receipt[@"pid"])) scope = VDTCheckText(localize, @"Selected instance only; total not recorded");
    if (!nice && multiple && !resourceSummary.present) scope = [scope stringByAppendingFormat:@"\n%@", VDTCheckText(localize,
        @"Other instance results were not retained in this receipt; this is not an all-instance success claim.")];
    NSString *coverage = VDTCheckText(localize, @"Coverage not recorded");
    if (historical || (resourceSummary.present && !resourceSummary.valid) || unavailable || invalid)
        coverage = VDTCheckText(localize, @"Current coverage not confirmed");
    else if (resourceSummary.valid) {
        VDTResourceSummaryCounts counts = resourceSummary.counts;
        coverage = !counts.total ? VDTCheckText(localize, @"No identified instances in this check.")
            : [NSString stringWithFormat:VDTCheckText(localize, @"Confirmed %@/%@; restored %@; not applied %@; pending %@; unknown %@; no action %@."),
                @(VDTResourceSummaryConfirmedCount(counts)), @(counts.total), @(counts.restored), @(counts.failed),
                @(counts.pending), @(counts.unknown), @(counts.disabled)];
    } else if (multiple) coverage = VDTCheckText(localize, @"Other instances have no retained count evidence.");
    else if ([tone isEqual:@"ok"]) coverage = VDTCheckText(localize, @"Only this recorded instance is confirmed.");
    NSString *interpretation = VDTCheckInterpretation(stateKey, unavailable, invalid, historical, localPending, multiple, resourceSummary, localize);
    if ([compactState isEqual:@"No restoration needed"])
        interpretation = VDTCheckText(localize, @"There was no recorded Vedette memory override to restore for these identified instances. No write was needed.");
    else if ([compactState isEqual:@"No write requested"])
        interpretation = VDTCheckText(localize, @"No write was requested for these identified instances. That is not a write failure.");
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
        VDTCheckField(@"scope", @"Recorded scope", scope, nil, localize),
        VDTCheckField(@"coverage", @"Coverage", coverage, nil, localize),
        VDTCheckField(@"policyNote", @"Interpretation", interpretation, nil, localize)
    ]];
    if (!nice) {
        [core addObject:VDTCheckField(@"lastAttempt", @"Last attempt", VDTCheckDate(latest[@"attemptedAt"]), nil, localize)];
        NSString *scanStatus = nil;
        if (latest) scanStatus = VDTCheckTrue(latest[@"enumerationComplete"])
            ? VDTCheckText(localize, @"Process list obtained; only identified instances are covered.")
            : VDTCheckText(localize, @"Process list incomplete; unidentified instances are not covered.");
        if ([VDTCheckInteger(latest[@"error"]) longLongValue] > 0)
            scanStatus = VDTCheckText(localize, @"The latest attempt could not complete the process list.");
        [core addObject:VDTCheckField(@"scanStatus", @"Latest attempt coverage", scanStatus, nil, localize)];
    }
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
        VDTCheckDiagnostic(diagnostics, @"localPending", @"Local check requested",
            localPending ? VDTCheckText(localize, @"Yes") : VDTCheckText(localize, @"No"), localize);
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
        BOOL hasCounts = resourceSummary.valid && !unavailable && !invalid;
        VDTResourceSummaryCounts counts = resourceSummary.counts;
        VDTCheckDiagnostic(diagnostics, @"summaryTotal", @"Identified instances", hasCounts ? @(counts.total).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryConfirmed", @"Confirmed instances",
            hasCounts ? @(VDTResourceSummaryConfirmedCount(counts)).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryApplied", @"Applied instances", hasCounts ? @(counts.applied).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryRestored", @"Restored instances", hasCounts ? @(counts.restored).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryFailed", @"Not-applied instances", hasCounts ? @(counts.failed).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryPending", @"Pending instances", hasCounts ? @(counts.pending).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryUnknown", @"Unknown instances", hasCounts ? @(counts.unknown).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"summaryDisabled", @"No-action instances", hasCounts ? @(counts.disabled).stringValue : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"checkBatch", @"Recorded check batch", VDTCheckNumber(receipt[@"checkBatch"]), localize);
        VDTCheckDiagnostic(diagnostics, @"latestBatch", @"Latest attempt batch", VDTCheckNumber(latest[@"batch"]), localize);
        VDTCheckDiagnostic(diagnostics, @"enumeration", @"Process list complete", latest
            ? VDTCheckText(localize, VDTCheckTrue(latest[@"enumerationComplete"]) ? @"Yes" : @"No") : nil, localize);
        VDTCheckDiagnostic(diagnostics, @"scanError", @"Scan error", VDTCheckNumber(latest[@"error"]), localize);
        VDTCheckDiagnostic(diagnostics, @"historical", @"Earlier result only", historical
            ? VDTCheckText(localize, @"Yes") : VDTCheckFalse(receipt[@"historicalOnly"]) ? VDTCheckText(localize, @"No") : nil, localize);
    }
    VDTCheckDiagnostic(diagnostics, @"settingsAvailable", @"Saved settings readable", unavailable
        ? VDTCheckText(localize, @"No") : VDTCheckTrue(rule[@"settingsAvailable"]) ? VDTCheckText(localize, @"Yes") : nil, localize);
    VDTCheckDiagnostic(diagnostics, @"configurationValid", @"Saved settings valid", unavailable ? nil
        : invalid ? VDTCheckText(localize, @"No") : VDTCheckTrue(rule[@"configurationValid"]) ? VDTCheckText(localize, @"Yes") : nil, localize);
    return @{@"title": VDTCheckText(localize, title), @"state": state, @"tone": tone,
        @"compactState": compactDisplay, @"compactTone": compactTone,
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
