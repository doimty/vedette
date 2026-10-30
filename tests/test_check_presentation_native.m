// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
// Production Model + Presentation, Foundation only. No Preferences or device IO.
#import "../vedetteprefs/VDTCheckPresentation.h"
#import "../vedetteprefs/VDTCheckResultModel.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define REQ(marker, ...) do { ++checks; if (!(__VA_ARGS__)) { \
    fprintf(stderr, "CHECK_PRESENTATION_FAIL:%s line %d\n", marker, __LINE__); abort(); \
} } while (0)

// These arrays deliberately mirror the public field contract, not the grouping
// implementation. The Python source-only check also compares them to the Model.
static NSArray *niceCoreIDs(void) {
    return @[@"state", @"target", @"observed", @"readTime", @"checkTime", @"scope", @"coverage", @"policyNote"];
}
static NSArray *resourceCoreIDs(void) {
    return @[@"state", @"target", @"observed", @"readTime", @"checkTime", @"scope", @"coverage", @"policyNote", @"lastAttempt", @"scanStatus"];
}
static NSArray *niceDiagnosticIDs(void) {
    return @[@"code", @"evidence", @"pid", @"instance", @"original", @"errno", @"receiptTime", @"pending", @"count", @"outcomes", @"writeCalls", @"retry", @"checkedTarget", @"revision", @"localPending", @"settingsAvailable", @"configurationValid"];
}
static NSArray *resourceDiagnosticIDs(void) {
    return @[@"code", @"evidence", @"pid", @"instance", @"planSkip", @"executionSkip", @"outcome", @"executor", @"errno", @"storeError", @"count", @"checkedTarget", @"action", @"rawReadback", @"readStart", @"summaryTotal", @"summaryConfirmed", @"summaryApplied", @"summaryRestored", @"summaryFailed", @"summaryPending", @"summaryUnknown", @"summaryDisabled", @"checkBatch", @"latestBatch", @"enumeration", @"scanError", @"historical", @"settingsAvailable", @"configurationValid"];
}

static NSArray *identifiers(NSArray *fields) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        REQ("field-id-is-string", [field[@"id"] isKindOfClass:NSString.class]);
        [ids addObject:field[@"id"]];
    }
    return ids;
}

static NSArray *expectedFields(NSDictionary *model, NSArray *ids) {
    NSArray *input = [model[@"coreFields"] arrayByAddingObjectsFromArray:model[@"diagnosticFields"]];
    NSMutableArray *expected = [NSMutableArray array];
    for (NSString *identifier in ids) {
        NSDictionary *found = nil;
        for (NSDictionary *field in input) {
            if ([field[@"id"] isEqual:identifier]) {
                REQ("fixture-no-duplicate", found == nil);
                found = field;
            }
        }
        REQ("fixture-field-present", found != nil);
        [expected addObject:found];
    }
    return expected;
}

static NSString *valueForID(NSArray *fields, NSString *identifier) {
    for (NSDictionary *field in fields)
        if ([field[@"id"] isEqual:identifier]) return field[@"value"];
    return nil;
}

static void checkProjection(NSDictionary *model, BOOL nice, BOOL future) {
    NSArray *expectedCore = nice ? niceCoreIDs() : resourceCoreIDs();
    NSArray *expectedDetails = nice ? niceDiagnosticIDs() : resourceDiagnosticIDs();
    if (future) {
        expectedCore = [expectedCore arrayByAddingObjectsFromArray:@[@"futureCore", @"futureCore2"]];
        expectedDetails = [expectedDetails arrayByAddingObjectsFromArray:@[@"futureDetail", @"futureDetail2"]];
    }
    REQ("model-core-ids-order", [identifiers(model[@"coreFields"]) isEqual:expectedCore]);
    REQ("model-diagnostic-ids-order", [identifiers(model[@"diagnosticFields"]) isEqual:expectedDetails]);
    NSArray *allInput = [model[@"coreFields"] arrayByAddingObjectsFromArray:model[@"diagnosticFields"]];
    NSArray *allInputIDs = identifiers(allInput);
    REQ("model-ids-unique", [NSSet setWithArray:allInputIDs].count == allInputIDs.count);
    for (NSDictionary *field in allInput) {
        for (NSString *key in @[@"id", @"label", @"value", @"tone"])
            REQ("model-field-shape", [field[key] isKindOfClass:NSString.class]);
    }

    NSArray *resultIDs = @[@"state", @"target", @"observed"];
    NSArray *checkIDs = nice ? @[@"readTime", @"checkTime", @"scope", @"coverage", @"policyNote"]
                             : @[@"readTime", @"checkTime", @"scope", @"coverage", @"policyNote", @"scanStatus"];
    if (future) checkIDs = [checkIDs arrayByAddingObjectsFromArray:@[@"futureCore", @"futureCore2"]];
    NSArray *identityIDs = nice ? @[@"code", @"evidence", @"pid", @"instance", @"original", @"count"]
                                : @[@"code", @"evidence", @"pid", @"instance", @"count"];
    NSArray *executionIDs = nice ? @[@"errno", @"writeCalls", @"checkedTarget"]
        : @[@"planSkip", @"executionSkip", @"outcome", @"executor", @"errno", @"storeError", @"checkedTarget", @"action", @"rawReadback", @"readStart"];
    NSArray *coverageIDs = nice ? @[@"receiptTime", @"pending", @"outcomes", @"retry", @"revision", @"localPending", @"settingsAvailable", @"configurationValid"]
        : @[@"summaryTotal", @"summaryConfirmed", @"summaryApplied", @"summaryRestored", @"summaryFailed", @"summaryPending", @"summaryUnknown", @"summaryDisabled", @"checkBatch", @"latestBatch", @"enumeration", @"scanError", @"historical", @"settingsAvailable", @"configurationValid"];
    if (future) coverageIDs = [coverageIDs arrayByAddingObjectsFromArray:@[@"futureDetail", @"futureDetail2"]];

    NSArray *primary = VDTCheckPresentationSections(model, NO);
    REQ("primary-section-count", primary.count == 2);
    REQ("primary-section-order", [primary[0][@"id"] isEqual:@"result"] && [primary[1][@"id"] isEqual:@"check"]);
    REQ("group-result", [primary[0][@"fields"] isEqual:expectedFields(model, resultIDs)]);
    REQ("group-check", [primary[1][@"fields"] isEqual:expectedFields(model, checkIDs)]);
    NSArray *primaryFields = VDTCheckPresentationFields(model, NO);
    REQ("primary-flatten", [primaryFields isEqual:[primary[0][@"fields"] arrayByAddingObjectsFromArray:primary[1][@"fields"]]]);

    NSArray *diagnostics = VDTCheckPresentationSections(model, YES);
    REQ("diagnostic-section-count", diagnostics.count == (nice ? 3u : 4u));
    NSArray *sectionIDs = nice ? @[@"identity", @"execution", @"coverage"]
                               : @[@"history", @"identity", @"execution", @"coverage"];
    REQ("diagnostic-section-order", [identifiers(diagnostics) isEqual:sectionIDs]);
    NSUInteger detailOffset = nice ? 0 : 1;
    if (!nice) REQ("group-history", [diagnostics[0][@"fields"] isEqual:expectedFields(model, @[@"lastAttempt"])]);
    REQ("group-identity", [diagnostics[detailOffset][@"fields"] isEqual:expectedFields(model, identityIDs)]);
    REQ("group-execution", [diagnostics[detailOffset + 1][@"fields"] isEqual:expectedFields(model, executionIDs)]);
    REQ("group-coverage", [diagnostics[detailOffset + 2][@"fields"] isEqual:expectedFields(model, coverageIDs)]);
    NSMutableArray *flattened = [NSMutableArray array];
    for (NSDictionary *section in diagnostics) [flattened addObjectsFromArray:section[@"fields"]];
    NSArray *diagnosticFields = VDTCheckPresentationFields(model, YES);
    REQ("diagnostic-flatten", [diagnosticFields isEqual:flattened]);

    NSArray *allOutput = [primaryFields arrayByAddingObjectsFromArray:diagnosticFields];
    NSArray *allOutputIDs = identifiers(allOutput);
    REQ("combined-count", allOutput.count == allInput.count);
    REQ("combined-unique", [NSSet setWithArray:allOutputIDs].count == allOutputIDs.count);
    REQ("combined-id-set", [[NSSet setWithArray:allOutputIDs] isEqual:[NSSet setWithArray:allInputIDs]]);
    for (NSDictionary *field in allOutput)
        REQ("complete-field-preserved", [field isEqual:expectedFields(model, @[field[@"id"]])[0]]);
}

static NSDictionary *summary(NSUInteger applied, NSUInteger failed, NSUInteger unknown) {
    return @{@"version": @1, @"batch": @7, @"scope": @"identified-targets", @"enumerationComplete": @YES,
        @"total": @(applied + failed + unknown), @"applied": @(applied), @"restored": @0,
        @"failed": @(failed), @"pending": @0, @"unknown": @(unknown), @"disabled": @0};
}

static NSMutableDictionary *resourceReceipt(NSDictionary *counts) {
    return [@{@"state": @"partial", @"memory": @"conflict", @"priority": @"applied",
        @"memoryObserved": @[@64, @1, @128, @1], @"priorityObserved": @15,
        @"memoryObservedAt": @1700000000, @"priorityObservedAt": @1700000000,
        @"memoryCheckedAt": @1700200000, @"priorityCheckedAt": @1700200000,
        @"checkedAt": @1700200000, @"memoryError": @13, @"pid": @42,
        @"memoryEvidence": @"read-before-conflict", @"instanceCount": @3,
        @"configurationValid": @YES, @"settingsAvailable": @YES,
        @"checkBatch": @7, @"summaries": @{@"memory": counts, @"priority": counts},
        @"latestCheck": @{@"version": @1, @"batch": @7, @"enumerationComplete": @YES,
            @"error": @0, @"attemptedAt": @1700400000}} mutableCopy];
}

static NSArray *models(NSDictionary *niceReceipt, NSDictionary *receipt) {
    return VDTCheckResultModels(@{@"requestedEnabled": @YES, @"valid": @YES, @"value": @10}, niceReceipt,
        @{@"enabled": @YES, @"active": @64, @"inactive": @128},
        @{@"enabled": @YES, @"priority": @15}, receipt, nil);
}

static NSString *dateAt(NSTimeInterval seconds) {
    return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds]
        dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
}

static NSDictionary *futureModel(NSDictionary *model) {
    NSMutableDictionary *result = [model mutableCopy];
    NSMutableArray *core = [model[@"coreFields"] mutableCopy];
    NSMutableArray *details = [model[@"diagnosticFields"] mutableCopy];
    [core addObjectsFromArray:@[
        @{@"id": @"futureCore", @"label": @"Unknown future label", @"value": @"9999999999999999999999999999999999999999999999999999999999999999", @"tone": @"warning", @"extra": @{@"retained": @YES}},
        @{@"id": @"futureCore2", @"label": @"Second future field", @"value": @"unknown / not live\nsecond line \u672a\u77e5", @"tone": @"custom-tone"}]];
    [details addObjectsFromArray:@[
        @{@"id": @"futureDetail", @"label": @"Unknown detail", @"value": @"warning: do not infer success", @"tone": @"warning"},
        @{@"id": @"futureDetail2", @"label": @"Second unknown detail", @"value": @"0000000000000000000000000000000000000001", @"tone": @"plain"}]];
    result[@"coreFields"] = core;
    result[@"diagnosticFields"] = details;
    return result;
}

static void checkInterleavedOrder(void) {
    NSDictionary *state = @{@"id": @"state", @"label": @"State", @"value": @"warning", @"tone": @"warning"};
    NSDictionary *observed = @{@"id": @"observed", @"label": @"Observed", @"value": @"12345678901234567890", @"tone": @"plain"};
    NSDictionary *unknownCore = @{@"id": @"newCore", @"label": @"Unrecognized", @"value": @"raw core", @"tone": @"future"};
    NSDictionary *readTime = @{@"id": @"readTime", @"label": @"Read", @"value": @"old time", @"tone": @"plain"};
    NSDictionary *checkTime = @{@"id": @"checkTime", @"label": @"Check", @"value": @"new time", @"tone": @"plain"};
    NSDictionary *scope = @{@"id": @"scope", @"label": @"Scope", @"value": @"unknown", @"tone": @"neutral"};
    NSDictionary *lastAttempt = @{@"id": @"lastAttempt", @"label": @"Attempt", @"value": @"newest attempt", @"tone": @"plain"};
    NSDictionary *unknownCore2 = @{@"id": @"newCore2", @"label": @"Other", @"value": @"raw core 2", @"tone": @"plain"};
    NSDictionary *code = @{@"id": @"code", @"label": @"Code", @"value": @"raw identity", @"tone": @"plain"};
    NSDictionary *count = @{@"id": @"count", @"label": @"Count", @"value": @"999999999999", @"tone": @"warning"};
    NSDictionary *error = @{@"id": @"errno", @"label": @"Error", @"value": @"13", @"tone": @"warning"};
    NSDictionary *unknownDetail = @{@"id": @"newDetail", @"label": @"Detail", @"value": @"unknown detail", @"tone": @"future"};
    NSDictionary *unknownDetail2 = @{@"id": @"newDetail2", @"label": @"Detail 2", @"value": @"keep order", @"tone": @"plain"};
    NSDictionary *model = @{@"coreFields": @[unknownCore, observed, readTime, checkTime, lastAttempt, state, scope, unknownCore2],
        @"diagnosticFields": @[unknownDetail, error, code, unknownDetail2, count]};
    NSArray *primary = @[@{@"id": @"result", @"fields": @[observed, state]},
        @{@"id": @"check", @"fields": @[unknownCore, readTime, checkTime, scope, unknownCore2]}];
    NSArray *details = @[@{@"id": @"history", @"fields": @[lastAttempt]},
        @{@"id": @"identity", @"fields": @[code, count]}, @{@"id": @"execution", @"fields": @[error]},
        @{@"id": @"coverage", @"fields": @[unknownDetail, unknownDetail2]}];
    REQ("interleaved-primary-order", [VDTCheckPresentationSections(model, NO) isEqual:primary]);
    REQ("interleaved-diagnostic-order", [VDTCheckPresentationSections(model, YES) isEqual:details]);
    REQ("interleaved-primary-flatten", [VDTCheckPresentationFields(model, NO) isEqual:@[observed, state, unknownCore, readTime, checkTime, scope, unknownCore2]]);
    REQ("interleaved-diagnostic-flatten", [VDTCheckPresentationFields(model, YES) isEqual:@[lastAttempt, code, count, error, unknownDetail, unknownDetail2]]);
}

static void checkInvalidModels(void) {
    REQ("nil-primary", VDTCheckPresentationSections(nil, NO).count == 0 && VDTCheckPresentationFields(nil, NO).count == 0);
    REQ("nil-diagnostics", VDTCheckPresentationSections(nil, YES).count == 0 && VDTCheckPresentationFields(nil, YES).count == 0);
    for (id bad in @[[NSNull null], @[], @"invalid", @42]) {
        REQ("invalid-model-primary", VDTCheckPresentationSections((NSDictionary *)bad, NO).count == 0 && VDTCheckPresentationFields((NSDictionary *)bad, NO).count == 0);
        REQ("invalid-model-diagnostics", VDTCheckPresentationSections((NSDictionary *)bad, YES).count == 0 && VDTCheckPresentationFields((NSDictionary *)bad, YES).count == 0);
    }
    REQ("missing-arrays", VDTCheckPresentationSections(@{}, NO).count == 0 && VDTCheckPresentationSections(@{}, YES).count == 0);
    REQ("invalid-arrays", VDTCheckPresentationSections(@{@"coreFields": @42, @"diagnosticFields": @"bad"}, NO).count == 0 &&
        VDTCheckPresentationSections(@{@"coreFields": @42, @"diagnosticFields": @"bad"}, YES).count == 0);
    NSDictionary *noID = @{@"label": @"missing id", @"value": @"preserve", @"tone": @"warning"};
    NSDictionary *badID = @{@"id": @42, @"label": @"invalid id", @"value": @"also preserve", @"tone": @"plain"};
    NSDictionary *badFields = @{@"coreFields": @[@"bad", @42, [NSNull null], noID, badID],
        @"diagnosticFields": @[@[], noID, badID]};
    NSArray *primary = VDTCheckPresentationSections(badFields, NO);
    NSArray *details = VDTCheckPresentationSections(badFields, YES);
    REQ("malformed-core-entries", primary.count == 1 && [primary[0][@"id"] isEqual:@"check"] &&
        [primary[0][@"fields"] isEqual:@[noID, badID]]);
    REQ("malformed-detail-entries", details.count == 1 && [details[0][@"id"] isEqual:@"coverage"] &&
        [details[0][@"fields"] isEqual:@[noID, badID]]);
    NSDictionary *onlyState = @{@"coreFields": @[@{@"id": @"state", @"label": @"state", @"value": @"unknown", @"tone": @"neutral"}]};
    REQ("only-result-no-empty-check", VDTCheckPresentationSections(onlyState, NO).count == 1 &&
        [VDTCheckPresentationSections(onlyState, NO)[0][@"id"] isEqual:@"result"]);
    REQ("no-diagnostics-or-history", VDTCheckPresentationSections(onlyState, YES).count == 0);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *niceReceipt = @{@"state": @"applied", @"original": @0, @"observed": @10, @"error": @0,
            @"targetCount": @1, @"checkedAt": @1700200000, @"oldestCheckedAt": @1700100000, @"observedAt": @1700000000};
        NSMutableDictionary *mixed = resourceReceipt(summary(2, 1, 0));
        NSArray *rows = models(niceReceipt, mixed);
        REQ("three-real-models", rows.count == 3);
        checkProjection(rows[0], YES, NO);
        checkProjection(rows[1], NO, NO);
        checkProjection(rows[2], NO, NO);
        NSArray *nicePrimary = VDTCheckPresentationFields(rows[0], NO);
        NSArray *niceDetails = VDTCheckPresentationFields(rows[0], YES);
        REQ("nice-no-attempt", valueForID(niceDetails, @"lastAttempt") == nil && valueForID(nicePrimary, @"scanStatus") == nil);
        REQ("nice-check-and-read-differ", [valueForID(nicePrimary, @"checkTime") isEqual:dateAt(1700100000)] &&
            [valueForID(nicePrimary, @"readTime") isEqual:dateAt(1700000000)] &&
            valueForID(niceDetails, @"readTime") == nil && valueForID(niceDetails, @"scope") == nil);

        NSDictionary *memory = rows[1];
        NSArray *primary = VDTCheckPresentationFields(memory, NO);
        NSArray *details = VDTCheckPresentationFields(memory, YES);
        REQ("mixed-warning-state", [valueForID(primary, @"state") isEqual:@"Changed; not overwritten"] &&
            [expectedFields(memory, @[@"state"])[0][@"tone"] isEqual:@"warning"]);
        REQ("mixed-coverage", [valueForID(primary, @"coverage") isEqual:@"Confirmed 2/3; restored 0; not applied 1; pending 0; unknown 0; no action 0."]);
        REQ("mixed-diagnostics", [valueForID(details, @"summaryFailed") isEqual:@"1"] && [valueForID(details, @"errno") isEqual:@"13"]);
        REQ("separate-history-and-attempt", [valueForID(primary, @"checkTime") isEqual:dateAt(1700200000)] &&
            [valueForID(primary, @"readTime") isEqual:dateAt(1700000000)] &&
            [valueForID(primary, @"scope") isEqual:@"Identified instances in this check only"] &&
            [valueForID(details, @"lastAttempt") isEqual:dateAt(1700400000)] &&
            valueForID(details, @"readTime") == nil && valueForID(details, @"scope") == nil &&
            valueForID(primary, @"lastAttempt") == nil);

        NSDictionary *future = futureModel(memory);
        checkProjection(future, NO, YES);
        REQ("unknown-long-number-unchanged", [valueForID(VDTCheckPresentationFields(future, NO), @"futureCore") isEqual:@"9999999999999999999999999999999999999999999999999999999999999999"]);
        REQ("unknown-warning-unchanged", [valueForID(VDTCheckPresentationFields(future, YES), @"futureDetail") isEqual:@"warning: do not infer success"]);

        NSMutableDictionary *updated = [mixed mutableCopy];
        updated[@"memory"] = @"read-failed";
        updated[@"memoryObserved"] = @[@2147483647, @1, @2147483647, @1];
        updated[@"memoryObservedAt"] = @1700800000;
        updated[@"memoryCheckedAt"] = @1700900000;
        updated[@"latestCheck"] = @{@"version": @1, @"batch": @7, @"enumerationComplete": @NO,
            @"error": @5, @"attemptedAt": @1701000000};
        NSMutableDictionary *updatedCounts = [summary(0, 3, 0) mutableCopy];
        updatedCounts[@"enumerationComplete"] = @NO;
        updated[@"summaries"] = @{@"memory": updatedCounts, @"priority": updatedCounts};
        NSDictionary *newMemory = models(niceReceipt, updated)[1];
        checkProjection(newMemory, NO, NO);
        NSArray *newPrimary = VDTCheckPresentationFields(newMemory, NO);
        NSArray *newDetails = VDTCheckPresentationFields(newMemory, YES);
        REQ("updated-state", [valueForID(newPrimary, @"state") isEqual:@"Readback failed"] &&
            ![valueForID(newPrimary, @"state") isEqual:valueForID(primary, @"state")]);
        REQ("updated-long-readback", [valueForID(newPrimary, @"observed") isEqual:@"2147483647 / 2147483647 MiB"]);
        REQ("updated-times-not-old", [valueForID(newPrimary, @"checkTime") isEqual:dateAt(1700900000)] &&
            [valueForID(newPrimary, @"readTime") isEqual:dateAt(1700800000)] &&
            [valueForID(newDetails, @"lastAttempt") isEqual:dateAt(1701000000)]);
        REQ("failed-counts-and-scan", [valueForID(newPrimary, @"coverage") isEqual:@"Confirmed 0/3; restored 0; not applied 3; pending 0; unknown 0; no action 0."] &&
            [valueForID(newDetails, @"summaryFailed") isEqual:@"3"] && [valueForID(newDetails, @"scanError") isEqual:@"5"]);
        REQ("old-projection-still-old", [valueForID(primary, @"observed") isEqual:@"64 / 128 MiB"] &&
            [valueForID(primary, @"checkTime") isEqual:dateAt(1700200000)] && [valueForID(primary, @"readTime") isEqual:dateAt(1700000000)]);
        NSMutableDictionary *sameModel = [memory mutableCopy];
        NSArray *beforeUpdate = VDTCheckPresentationFields(sameModel, NO);
        sameModel[@"coreFields"] = newMemory[@"coreFields"];
        sameModel[@"diagnosticFields"] = newMemory[@"diagnosticFields"];
        NSArray *afterUpdate = VDTCheckPresentationFields(sameModel, NO);
        NSArray *afterUpdateDetails = VDTCheckPresentationFields(sameModel, YES);
        REQ("same-model-updated-values", [valueForID(beforeUpdate, @"state") isEqual:@"Changed; not overwritten"] &&
            [valueForID(afterUpdate, @"state") isEqual:@"Readback failed"] &&
            [valueForID(afterUpdate, @"observed") isEqual:@"2147483647 / 2147483647 MiB"]);
        REQ("same-model-updated-times", [valueForID(afterUpdate, @"checkTime") isEqual:dateAt(1700900000)] &&
            [valueForID(afterUpdate, @"readTime") isEqual:dateAt(1700800000)] &&
            [valueForID(afterUpdateDetails, @"lastAttempt") isEqual:dateAt(1701000000)]);

        NSMutableDictionary *missing = [updated mutableCopy];
        [missing removeObjectForKey:@"memoryObservedAt"];
        [missing removeObjectForKey:@"memoryCheckedAt"];
        [missing removeObjectForKey:@"checkedAt"];
        missing[@"memoryObserved"] = @[@64, @1];
        NSDictionary *missingMemory = models(niceReceipt, missing)[1];
        checkProjection(missingMemory, NO, NO);
        NSArray *missingPrimary = VDTCheckPresentationFields(missingMemory, NO);
        NSArray *missingDetails = VDTCheckPresentationFields(missingMemory, YES);
        REQ("no-borrowed-readback-or-time", [valueForID(missingPrimary, @"observed") isEqual:@"Not recorded"] &&
            [valueForID(missingPrimary, @"checkTime") isEqual:@"Not recorded"] &&
            [valueForID(missingPrimary, @"readTime") isEqual:@"Not recorded"] &&
            [valueForID(missingDetails, @"lastAttempt") isEqual:dateAt(1701000000)]);

        NSDictionary *unknownMemory = models(niceReceipt, resourceReceipt(summary(0, 1, 2)))[1];
        checkProjection(unknownMemory, NO, NO);
        REQ("unknown-counts-not-invented", [valueForID(VDTCheckPresentationFields(unknownMemory, YES), @"summaryUnknown") isEqual:@"2"] &&
            [valueForID(VDTCheckPresentationFields(unknownMemory, NO), @"coverage") isEqual:@"Confirmed 0/3; restored 0; not applied 1; pending 0; unknown 2; no action 0."]);
        NSMutableDictionary *pendingNice = [niceReceipt mutableCopy];
        pendingNice[@"localPending"] = @YES;
        pendingNice[@"receiptUpdatedAt"] = @1701000000;
        NSDictionary *newNice = models(pendingNice, mixed)[0];
        checkProjection(newNice, YES, NO);
        REQ("nice-pending-keeps-historical-times", [valueForID(VDTCheckPresentationFields(newNice, NO), @"checkTime") isEqual:dateAt(1700100000)] &&
            [valueForID(VDTCheckPresentationFields(newNice, NO), @"readTime") isEqual:dateAt(1700000000)] &&
            [valueForID(VDTCheckPresentationFields(newNice, YES), @"localPending") isEqual:@"Yes"]);
        NSMutableDictionary *noDetails = [rows[0] mutableCopy];
        [noDetails removeObjectForKey:@"diagnosticFields"];
        REQ("nice-missing-diagnostic-groups", VDTCheckPresentationSections(noDetails, YES).count == 0 &&
            VDTCheckPresentationFields(noDetails, YES).count == 0 &&
            [VDTCheckPresentationFields(noDetails, NO) isEqual:nicePrimary]);
        NSMutableDictionary *resourceNoDetails = [memory mutableCopy];
        [resourceNoDetails removeObjectForKey:@"diagnosticFields"];
        NSArray *historyOnly = VDTCheckPresentationSections(resourceNoDetails, YES);
        REQ("resource-missing-diagnostic-groups", historyOnly.count == 1 && [historyOnly[0][@"id"] isEqual:@"history"] &&
            [historyOnly[0][@"fields"] isEqual:@[memory[@"coreFields"][8]]] &&
            [identifiers(historyOnly[0][@"fields"]) isEqual:@[@"lastAttempt"]] &&
            [VDTCheckPresentationFields(resourceNoDetails, NO) isEqual:primary]);
        checkInterleavedOrder();
        checkInvalidModels();
        printf("PASS check-presentation: %u checks; Foundation/CoreFoundation, no UIKit, Preferences or device IO\n", checks);
    }
    return 0;
}
