// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
// Real Foundation display projection. No Preferences/UIKit, disk or kernel IO.
#import "../vedetteprefs/VDTCheckResultModel.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <errno.h>
static unsigned checks;
#define REQ(tag, ...) do { ++checks; if (!(__VA_ARGS__)) { fprintf(stderr, "CHECK_MODEL_FAIL:%s line %d\n", tag, __LINE__); abort(); } } while (0)
static BOOL contains(NSString *text, NSString *fragment) { return [text isKindOfClass:NSString.class] && [text rangeOfString:fragment].location != NSNotFound; }
static void checkShape(NSArray *rows);
static NSArray *project(NSDictionary *nice, NSDictionary *memory, NSDictionary *priority, NSDictionary *receipt) {
    NSArray *rows = VDTCheckResultModels(@{@"requestedEnabled":@YES,@"valid":@YES,@"value":@10},nice,
        memory ?: @{@"enabled":@YES,@"active":@64,@"inactive":@128},
        priority ?: @{@"enabled":@YES,@"priority":@15},receipt,^NSString *(NSString *key) { return key; });
    checkShape(rows);
    return rows;
}
static NSString *fieldValue(NSDictionary *row, NSString *collection, NSString *identifier) {
    for (NSDictionary *field in row[collection]) if ([field[@"id"] isEqual:identifier]) return field[@"value"];
    return nil;
}
static NSString *detail(NSDictionary *row) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *field in row[@"diagnosticFields"])
        [lines addObject:[NSString stringWithFormat:@"%@: %@", field[@"label"], field[@"value"]]];
    return [lines componentsJoinedByString:@"\n"];
}
static void checkShape(NSArray *rows) {
    static NSArray *coreIDs[3], *diagnosticIDs[3];
    REQ("three-rows", rows.count == 3);
    REQ("row-order", [rows[0][@"title"] isEqual:@"nice"] && [rows[1][@"title"] isEqual:@"Memory"] && [rows[2][@"title"] isEqual:@"Reclaim priority"]);
    for (NSUInteger index = 0; index < rows.count; ++index) {
        NSDictionary *row = rows[index];
        for (NSString *key in @[@"title",@"state",@"tone",@"summary",@"timestamp",@"scope",@"compactState",@"compactTone"])
            REQ("string-fields", [row[key] isKindOfClass:NSString.class] && [row[key] length] > 0);
        REQ("stable-core-fields", [row[@"coreFields"] count] == (index == 0 ? 8 : 10) && row[@"details"] == nil);
        for (NSString *collection in @[@"coreFields", @"diagnosticFields"]) {
            NSMutableSet *unique = [NSMutableSet set]; NSMutableArray *ids = [NSMutableArray array];
            for (NSDictionary *field in row[collection]) {
                REQ("field-shape", [field[@"value"] isKindOfClass:NSString.class] && [field[@"label"] length] > 0 && [field[@"id"] length] > 0);
                REQ("field-id-unique", ![unique containsObject:field[@"id"]]); [unique addObject:field[@"id"]]; [ids addObject:field[@"id"]];
            }
            NSArray *__strong *expected = [collection isEqual:@"coreFields"] ? &coreIDs[index] : &diagnosticIDs[index];
            if (!*expected) *expected = [ids copy];
            REQ("stable-field-ids-and-counts", [*expected isEqual:ids]);
        }
        REQ("always-interpretation", [fieldValue(row,@"coreFields",@"policyNote") length] > 0);
        REQ("always-coverage", [fieldValue(row,@"coreFields",@"coverage") length] > 0);
        for (NSString *rawKey in @[@"code", @"errno", @"rawReadback", @"pid", @"scanError", @"checkBatch"])
            REQ("raw-out-of-core", fieldValue(row,@"coreFields",rawKey) == nil);
    }
}
static NSDictionary *summaryCounts(uint32_t total, uint32_t applied, uint32_t restored, uint32_t failed,
    uint32_t pending, uint32_t unknown, uint32_t disabled) {
    return @{@"version": @1, @"batch": @7, @"scope": @"identified-targets", @"enumerationComplete": @YES,
        @"total": @(total), @"applied": @(applied), @"restored": @(restored), @"failed": @(failed),
        @"pending": @(pending), @"unknown": @(unknown), @"disabled": @(disabled)};
}
static NSMutableDictionary *countedReceipt(NSDictionary *receipt, NSDictionary *memory, NSDictionary *priority) {
    NSMutableDictionary *row = [receipt mutableCopy] ?: [NSMutableDictionary dictionary];
    row[@"checkBatch"] = @7;
    row[@"summaries"] = @{@"memory": memory ?: @{}, @"priority": priority ?: memory ?: @{}};
    row[@"latestCheck"] = @{@"version": @1, @"batch": @7, @"enumerationComplete": @YES, @"error": @0, @"attemptedAt": @1700001000};
    row[@"configurationValid"] = @YES;
    row[@"settingsAvailable"] = @YES;
    return row;
}
static void checkUnknownSummary(NSDictionary *nice, NSDictionary *base, NSDictionary *summary) {
    NSArray *rows = project(nice,nil,nil,countedReceipt(base,summary,nil));
    REQ("summary-malformed-unknown", [rows[1][@"compactState"] isEqual:@"Not confirmed"] && ![rows[1][@"compactTone"] isEqual:@"ok"]);
    REQ("summary-unknown-keeps-readback", contains(rows[1][@"summary"],@"Last read back: 64 / 128 MiB"));
    REQ("summary-unknown-keeps-check-time", ![fieldValue(rows[1],@"coreFields",@"checkTime") isEqual:@"Not recorded"]);
    REQ("summary-malformed-no-inferred-count", [fieldValue(rows[1],@"diagnosticFields",@"summaryTotal") isEqual:@"Not recorded"]);
}
int main(void) {
    @autoreleasepool {
        NSDictionary *nice = @{@"state":@"applied",@"original":@0,@"observed":@10,@"error":@0,@"pendingCount":@0,@"targetCount":@1,@"checkedAt":@1700000010,@"oldestCheckedAt":@1700000000,@"observedAt":@1700000000};
        NSDictionary *base = @{@"state":@"applied",@"memory":@"applied",@"priority":@"applied",@"memorySkip":@0,@"prioritySkip":@0,@"memoryObserved":@[@64,@1,@128,@1],@"priorityObserved":@15,@"memoryObservedAt":@1700000004,@"priorityObservedAt":@1700000004,@"checkedAt":@1700000005,@"pid":@42};
        NSArray *rows = project(nice,nil,nil,base); checkShape(rows);
        for (NSDictionary *row in rows)
            REQ("compact-confirmed", [row[@"compactState"] isEqual:@"Confirmed"] && [row[@"compactTone"] isEqual:@"ok"]);
        NSArray *missing = project(nil,nil,nil,nil);
        for (NSDictionary *row in missing)
            REQ("compact-missing-not-success", [row[@"compactState"] isEqual:@"Not confirmed"] && ![row[@"compactTone"] isEqual:@"ok"]);
        NSArray *pending = project(@{@"state":@"pending"},nil,nil,@{@"state":@"pending"});
        for (NSDictionary *row in pending) REQ("compact-pending", [row[@"compactState"] isEqual:@"Pending"]);
        NSMutableDictionary *restored = [base mutableCopy]; restored[@"memory"] = @"restored";
        REQ("compact-restored", [project(nice,nil,nil,restored)[1][@"compactState"] isEqual:@"Restored"]);
        REQ("matched-side", [rows[1][@"state"] isEqual:@"Rule readback matched"] && [rows[2][@"state"] isEqual:@"Rule readback matched"]);
        REQ("target-vs-readback", contains(rows[1][@"summary"],@"Saved target (active / inactive): 64 / 128 MiB") && contains(rows[1][@"summary"],@"Last read back: 64 / 128 MiB"));
        REQ("hide-raw-pair", !contains(rows[1][@"summary"],@"Raw memory") && contains(detail(rows[1]),@"[64, 1, 128, 1]"));
        REQ("nice-detail-only", !contains(rows[0][@"summary"],@"errno") && contains(detail(rows[0]),@"Original: 0") && contains(detail(rows[0]),@"Pending targets: 0"));
        NSString *oldest = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:1700000000]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
        REQ("receipt-time", [rows[0][@"timestamp"] isEqual:[@"Last check: " stringByAppendingString:oldest]]);

        NSMutableDictionary *changed = [base mutableCopy]; [changed removeObjectForKey:@"priority"];
        [changed removeObjectForKey:@"priorityObserved"]; changed[@"prioritySkip"]=@3;
        rows=project(nice,nil,nil,changed);
        REQ("skip-not-success", [rows[2][@"state"] isEqual:@"Rule not applied"]);
        NSString *policyNote = @"This rule was rejected. A policy skip is not a system-write failure.";
        REQ("skip-explanation", [fieldValue(rows[2], @"coreFields", @"policyNote") isEqual:policyNote]);
        REQ("skip-note-core-only", !contains(detail(rows[2]), @"policy skip"));
        NSArray *localized = VDTCheckResultModels(nil, nil, nil, nil, changed, ^NSString *(NSString *key) {
            return [key isEqual:policyNote] ? @"localized policy note" : key;
        });
        REQ("skip-note-localized", [fieldValue(localized[2], @"coreFields", @"policyNote") isEqual:@"localized policy note"]);
        REQ("nil-not-a-text-match", !contains(nil, @"policy skip"));
        REQ("skip-not-system", !contains(rows[2][@"state"],@"system") && [rows[1][@"tone"] isEqual:@"ok"]);
        REQ("missing-readback", contains(rows[2][@"summary"],@"Last read back: Not recorded"));
        changed[@"priority"]=@"conflict"; changed[@"prioritySkip"]=@0; changed[@"state"]=@"conflict";
        rows=project(nice,nil,nil,changed);
        REQ("priority-conflict", [rows[2][@"state"] isEqual:@"Changed; not overwritten"] && [rows[1][@"state"] isEqual:@"Rule readback matched"]);
        REQ("compact-failure", [rows[2][@"compactState"] isEqual:@"Not applied"] && [rows[2][@"compactTone"] isEqual:@"warning"]);
        REQ("conflict-no-invention", contains(rows[2][@"summary"],@"Last read back: Not recorded"));
        changed=[base mutableCopy]; changed[@"state"]=@"conflict"; changed[@"memory"]=@"conflict";
        [changed removeObjectForKey:@"memoryObserved"]; rows=project(nice,nil,nil,changed);
        REQ("memory-conflict", [rows[1][@"tone"] isEqual:@"warning"] && [rows[2][@"state"] isEqual:@"Rule readback matched"]);
        NSDictionary *sideReceipts = @{
            @"state": @"partial", @"multipleInstances": @YES, @"instanceCount": @2,
            @"sideReceipts": @{
                @"memory": @{@"state": @"partial", @"memory": @"applied", @"memoryObserved": @[@64,@1,@128,@1],
                    @"memoryCheckedAt": @1700000011, @"memoryEvidence": @"written-verified", @"pid": @42, @"checkedAt": @1700000011},
                @"priority": @{@"state": @"partial", @"priority": @"conflict", @"priorityObserved": @21,
                    @"priorityCheckedAt": @1700000012, @"priorityEvidence": @"read-before-conflict", @"pid": @43, @"checkedAt": @1700000012}
            }
        };
        rows=project(nice,nil,nil,sideReceipts);
        REQ("compact-selected-instance", [rows[1][@"compactState"] isEqual:@"Selected instance confirmed"] && [rows[1][@"compactTone"] isEqual:@"ok"]);
        REQ("side-receipt-observed", [rows[2][@"state"] isEqual:@"Changed; not overwritten"] &&
            contains(rows[2][@"summary"], @"Last read back: 21") && contains(detail(rows[2]), @"read-before-conflict"));
        // Directed batch summaries: counts, not a multi-instance qualifier,
        // determine compact confirmation. Selected-side diagnostics stay real.
        NSDictionary *allConfirmed = summaryCounts(3,3,0,0,0,0,0);
        NSMutableDictionary *batch = countedReceipt(base,allConfirmed,nil);
        rows=project(nice,nil,nil,batch);
        REQ("summary-all-confirmed", [rows[1][@"compactState"] isEqual:@"Confirmed (3/3)"] &&
            [rows[2][@"compactState"] isEqual:@"Confirmed (3/3)"] && [rows[1][@"compactTone"] isEqual:@"ok"]);
        REQ("summary-identified-scope", [rows[1][@"scope"] isEqual:@"Identified instances in this check only"] && !contains(rows[1][@"scope"],@"device"));
        REQ("summary-confirmed-counts", [fieldValue(rows[1],@"diagnosticFields",@"summaryConfirmed") isEqual:@"3"] &&
            [fieldValue(rows[1],@"diagnosticFields",@"summaryTotal") isEqual:@"3"] && [fieldValue(rows[1],@"diagnosticFields",@"summaryUnknown") isEqual:@"0"]);
        NSDictionary *singleSummary = summaryCounts(1,1,0,0,0,0,0);
        REQ("summary-single-confirmed", [project(nice,nil,nil,countedReceipt(base,singleSummary,nil))[1][@"compactState"] isEqual:@"Confirmed"]);
        NSDictionary *allRestored = summaryCounts(3,0,3,0,0,0,0);
        REQ("summary-all-restored", [project(nice,nil,nil,countedReceipt(base,allRestored,nil))[1][@"compactState"] isEqual:@"Restored"]);
        NSMutableDictionary *failureSides = [sideReceipts mutableCopy];
        NSMutableDictionary *worstMemory = [sideReceipts[@"sideReceipts"][@"memory"] mutableCopy];
        worstMemory[@"memory"] = @"conflict"; worstMemory[@"memoryEvidence"] = @"read-before-conflict"; worstMemory[@"memoryError"] = @(EACCES);
        failureSides[@"sideReceipts"] = @{@"memory":worstMemory,@"priority":sideReceipts[@"sideReceipts"][@"priority"]};
        failureSides[@"instanceCount"] = @3;
        batch=countedReceipt(failureSides,summaryCounts(3,2,0,1,0,0,0),allConfirmed);
        rows=project(nice,nil,nil,batch);
        REQ("summary-partial-failure", [rows[1][@"compactState"] isEqual:@"Partly confirmed (2/3)"] && [rows[1][@"compactTone"] isEqual:@"warning"]);
        REQ("summary-preserves-worst-reason", [rows[1][@"state"] isEqual:@"Changed; not overwritten"] &&
            [fieldValue(rows[1],@"diagnosticFields",@"errno") isEqual:[@(EACCES) stringValue]] && contains(detail(rows[1]),@"read-before-conflict"));
        REQ("summary-independent-sides", [rows[2][@"compactState"] isEqual:@"Confirmed (3/3)"] && [rows[2][@"state"] isEqual:@"Changed; not overwritten"]);
        REQ("summary-propagated-batch", [fieldValue(rows[1],@"diagnosticFields",@"checkBatch") isEqual:@"7"] &&
            [fieldValue(rows[1],@"diagnosticFields",@"latestBatch") isEqual:@"7"] && [fieldValue(rows[1],@"diagnosticFields",@"summaryFailed") isEqual:@"1"]);
        rows=project(nice,nil,nil,countedReceipt(failureSides,summaryCounts(3,0,0,3,0,0,0),nil));
        REQ("summary-all-failed", [rows[1][@"compactState"] isEqual:@"Not applied"] && [rows[1][@"compactTone"] isEqual:@"warning"]);
        rows=project(nice,nil,nil,countedReceipt(base,summaryCounts(3,0,0,0,3,0,0),nil));
        REQ("summary-pending", [rows[1][@"compactState"] isEqual:@"Pending"] && [rows[1][@"compactTone"] isEqual:@"neutral"]);
        rows=project(nice,nil,nil,countedReceipt(base,summaryCounts(3,0,0,0,2,1,0),nil));
        REQ("summary-unknown-not-pending", [rows[1][@"compactState"] isEqual:@"Not confirmed"] &&
            [fieldValue(rows[1],@"diagnosticFields",@"summaryPending") isEqual:@"2"] && [fieldValue(rows[1],@"diagnosticFields",@"summaryUnknown") isEqual:@"1"]);
        rows=project(nice,nil,nil,countedReceipt(base,summaryCounts(3,1,0,0,1,1,0),nil));
        REQ("summary-partial-keeps-pending-unknown", [rows[1][@"compactState"] isEqual:@"Partly confirmed (1/3)"] &&
            [fieldValue(rows[1],@"diagnosticFields",@"summaryPending") isEqual:@"1"] && [fieldValue(rows[1],@"diagnosticFields",@"summaryUnknown") isEqual:@"1"]);
        rows=project(nice,nil,nil,countedReceipt(base,summaryCounts(0,0,0,0,0,0,0),nil));
        REQ("summary-empty-not-success", [rows[1][@"compactState"] isEqual:@"Not confirmed"] &&
            [fieldValue(rows[1],@"diagnosticFields",@"summaryTotal") isEqual:@"0"] && contains(fieldValue(rows[1],@"coreFields",@"policyNote"),@"empty result is not a success"));
        NSDictionary *noAction = summaryCounts(3,0,0,0,0,0,3);
        rows=project(nice,@{@"enabled":@YES,@"active":@0,@"inactive":@0},nil,countedReceipt(base,noAction,nil));
        REQ("summary-unnecessary-restoration", [rows[1][@"compactState"] isEqual:@"No restoration needed"] && [rows[1][@"compactTone"] isEqual:@"neutral"]);
        REQ("summary-no-action-count", [fieldValue(rows[1],@"diagnosticFields",@"summaryDisabled") isEqual:@"3"] && contains(fieldValue(rows[1],@"coreFields",@"policyNote"),@"No write was needed"));
        rows=project(nice,@{@"enabled":@NO},nil,countedReceipt(base,noAction,nil));
        REQ("summary-disabled-not-failure", [rows[1][@"compactState"] isEqual:@"Not enabled"] && [rows[1][@"compactTone"] isEqual:@"neutral"]);
        rows=project(nice,@{@"enabled":@YES,@"active":@0,@"inactive":@0,@"globallyEnabled":@NO},nil,countedReceipt(base,noAction,nil));
        REQ("summary-paused-not-failure", [rows[1][@"compactState"] isEqual:@"Paused"] && [rows[1][@"compactTone"] isEqual:@"neutral"]);

        // Missing/coerced/bounded counters and explicit malformed envelopes never
        // fall back to the legacy success row, but keep historical readbacks.
        NSMutableDictionary *badSummary=[allConfirmed mutableCopy]; [badSummary removeObjectForKey:@"unknown"];
        checkUnknownSummary(nice,base,badSummary);
        for (id badCount in @[@YES,@3.0,@"3",@(-1),@65537,@(UINT32_MAX)]) {
            badSummary=[allConfirmed mutableCopy]; badSummary[@"total"]=badCount; checkUnknownSummary(nice,base,badSummary);
        }
        badSummary=[allConfirmed mutableCopy]; badSummary[@"failed"]=@1; checkUnknownSummary(nice,base,badSummary);
        for (NSString *key in @[@"version",@"batch",@"scope",@"enumerationComplete"]) {
            badSummary=[allConfirmed mutableCopy]; [badSummary removeObjectForKey:key]; checkUnknownSummary(nice,base,badSummary);
        }
        for (NSDictionary *invalidFields in @[@{@"version":@YES},@{@"version":@2},@{@"batch":@YES},@{@"batch":@0},
            @{@"scope":@"all-device-targets"},@{@"enumerationComplete":@1}]) {
            badSummary=[allConfirmed mutableCopy]; [badSummary addEntriesFromDictionary:invalidFields]; checkUnknownSummary(nice,base,badSummary);
        }
        for (id malformed in @[[NSNull null],@[],@"invalid",@7]) {
            batch=countedReceipt(base,allConfirmed,nil); batch[@"summaries"]=malformed;
            rows=project(nice,nil,nil,batch); REQ("summary-envelope-malformed", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
            batch=countedReceipt(base,allConfirmed,nil); batch[@"summaries"]=@{@"memory":malformed,@"priority":allConfirmed};
            rows=project(nice,nil,nil,batch); REQ("summary-side-malformed", [rows[1][@"compactState"] isEqual:@"Not confirmed"] && [rows[2][@"compactState"] isEqual:@"Confirmed (3/3)"]);
            batch=countedReceipt(base,allConfirmed,nil); batch[@"sideReceipts"]=malformed;
            rows=project(nice,nil,nil,batch); REQ("summary-side-receipt-malformed", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        }
        for (NSString *key in @[@"checkBatch",@"latestCheck",@"summaries"]) {
            batch=countedReceipt(base,allConfirmed,nil); [batch removeObjectForKey:key]; rows=project(nice,nil,nil,batch);
            REQ("summary-new-envelope-missing", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        }
        batch=countedReceipt(base,allConfirmed,nil); batch[@"checkBatch"]=@8; rows=project(nice,nil,nil,batch);
        REQ("summary-stale-row", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        batch=countedReceipt(base,allConfirmed,nil); NSMutableDictionary *latest=[batch[@"latestCheck"] mutableCopy]; latest[@"batch"]=@8; batch[@"latestCheck"]=latest;
        rows=project(nice,nil,nil,batch); REQ("summary-stale-latest", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        for (NSDictionary *invalidLatest in @[@{@"version":@YES},@{@"batch":@YES},@{@"enumerationComplete":@1},
            @{@"error":@YES},@{@"error":@(-1)},@{@"error":@(UINT32_MAX)},@{@"attemptedAt":@YES},@{@"attemptedAt":@0}]) {
            batch=countedReceipt(base,allConfirmed,nil); latest=[batch[@"latestCheck"] mutableCopy]; [latest addEntriesFromDictionary:invalidLatest]; batch[@"latestCheck"]=latest;
            rows=project(nice,nil,nil,batch); REQ("summary-latest-malformed", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        }
        badSummary=[allConfirmed mutableCopy]; badSummary[@"enumerationComplete"]=@NO;
        batch=countedReceipt(base,badSummary,nil); rows=project(nice,nil,nil,batch);
        REQ("summary-enumeration-disagrees", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        latest=[batch[@"latestCheck"] mutableCopy]; latest[@"enumerationComplete"]=@NO; latest[@"error"]=@(EIO); batch[@"latestCheck"]=latest;
        rows=project(nice,nil,nil,batch);
        REQ("summary-incomplete-identified-only", [rows[1][@"compactState"] isEqual:@"Confirmed (3/3)"] && contains(fieldValue(rows[1],@"coreFields",@"scanStatus"),@"could not complete"));
        REQ("summary-scan-error-detail-only", [fieldValue(rows[1],@"diagnosticFields",@"scanError") isEqual:[@(EIO) stringValue]] && !contains(rows[1][@"compactState"],@"error"));
        REQ("summary-attempt-not-check-time", ![fieldValue(rows[1],@"coreFields",@"lastAttempt") isEqual:fieldValue(rows[1],@"coreFields",@"checkTime")]);
        batch=countedReceipt(base,allConfirmed,nil); batch[@"historicalOnly"]=@YES; [batch removeObjectForKey:@"summaries"];
        latest=[batch[@"latestCheck"] mutableCopy]; latest[@"batch"]=@8; batch[@"latestCheck"]=latest; rows=project(nice,nil,nil,batch);
        NSDictionary *oldMemory=project(nice,nil,nil,base)[1];
        REQ("summary-historical-only-unknown", [rows[1][@"compactState"] isEqual:@"Not confirmed"] && contains(fieldValue(rows[1],@"coreFields",@"policyNote"),@"earlier recorded result"));
        REQ("summary-historical-no-lent-time", [fieldValue(rows[1],@"coreFields",@"checkTime") isEqual:fieldValue(oldMemory,@"coreFields",@"checkTime")] &&
            [fieldValue(rows[1],@"coreFields",@"readTime") isEqual:fieldValue(oldMemory,@"coreFields",@"readTime")] && [fieldValue(rows[1],@"coreFields",@"observed") isEqual:fieldValue(oldMemory,@"coreFields",@"observed")]);
        REQ("summary-historical-no-new-counts", [fieldValue(rows[1],@"diagnosticFields",@"summaryConfirmed") isEqual:@"Not recorded"]);
        batch=countedReceipt(base,allConfirmed,nil); batch[@"historicalOnly"]=@YES; rows=project(nice,nil,nil,batch);
        REQ("summary-historical-illicit-counts", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        batch=countedReceipt(base,allConfirmed,nil); batch[@"historicalOnly"]=@1; rows=project(nice,nil,nil,batch);
        REQ("summary-historical-boolean-required", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        changed=[base mutableCopy]; [changed removeObjectForKey:@"memory"]; [changed removeObjectForKey:@"priority"];
        rows=project(nice,nil,nil,changed);
        REQ("no-overall-fallback", [rows[1][@"state"] isEqual:@"Side result not recorded"] && [rows[2][@"state"] isEqual:@"Side result not recorded"]);

        changed=[base mutableCopy]; changed[@"memoryObserved"]=@[@(INT32_MAX),@0,@(INT32_MAX),@0];
        rows=project(nice,@{@"enabled":@YES,@"active":@(-1),@"inactive":@(-1)},nil,changed);
        REQ("full-unlimited", contains(rows[1][@"summary"],@"Last read back: Unlimited / Unlimited"));
        for (NSArray *notUnlimited in @[@[@(INT32_MAX),@1,@(INT32_MAX),@0],@[@(INT32_MAX),@0,@(INT32_MAX),@1],
            @[@(INT32_MAX),@0,@64,@0],@[@64,@0,@(INT32_MAX),@0],@[@(-1),@0,@(-1),@0],@[@(INT32_MAX),@NO,@(INT32_MAX),@0]]) {
            changed[@"memoryObserved"]=notUnlimited; rows=project(nice,nil,nil,changed);
            REQ("reject-partial-unlimited", !contains(rows[1][@"summary"],@"Last read back: Unlimited"));
        }
        rows=project(nice,@{@"enabled":@YES,@"active":@(-1),@"inactive":@0},nil,base);
        REQ("mixed-target", contains(rows[1][@"summary"],@"Incompatible settings"));
        rows=project(nice,@{@"enabled":@YES,@"active":@0,@"inactive":@0},nil,base);
        REQ("restore-target", contains(rows[1][@"summary"],@"Restore recorded value"));
        rows=project(nice,@{@"enabled":@YES,@"active":@NO,@"inactive":@0},nil,base);
        REQ("bool-not-number", contains(rows[1][@"summary"],@"Incomplete settings"));
        rows=project(nice,@{@"enabled":@YES,@"active":@64},nil,base);
        REQ("missing-field", contains(rows[1][@"summary"],@"Incomplete settings"));
        rows=project(nil,@{@"enabled":@NO,@"active":@64,@"inactive":@128},nil,nil);
        REQ("disabled-not-applied", contains(rows[1][@"summary"],@"Saved target (active / inactive): Off") && ![rows[1][@"tone"] isEqual:@"ok"]);
        REQ("compact-disabled", [rows[1][@"compactState"] isEqual:@"Not enabled"] && ![rows[1][@"compactTone"] isEqual:@"ok"]);
        REQ("unknown-time", [rows[1][@"timestamp"] isEqual:@"Check time not recorded"]);
        changed=[base mutableCopy]; changed[@"multipleInstances"]=@YES;
        rows=project(nice,nil,nil,changed);
        REQ("representative-only", contains(rows[1][@"scope"],@"selected instance only") && contains(detail(rows[1]),@"Selected PID: 42"));
        NSMutableDictionary *many=[nice mutableCopy]; many[@"targetCount"]=@2;
        rows=project(many,nil,nil,base);
        REQ("nice-no-aggregate-value", contains(rows[0][@"summary"],@"Last read back: Not recorded") && contains(rows[0][@"scope"],@"individual readbacks unavailable"));
        NSDictionary *oldNice=project(nice,nil,nil,base)[0];
        NSMutableDictionary *localCheck=[nice mutableCopy]; localCheck[@"localPending"]=@YES; localCheck[@"receiptUpdatedAt"]=@1700001000;
        rows=project(localCheck,nil,nil,base);
        REQ("nice-local-pending", [rows[0][@"compactState"] isEqual:@"Checking…"] && [rows[0][@"compactTone"] isEqual:@"neutral"]);
        REQ("nice-local-pending-keeps-history", [fieldValue(rows[0],@"coreFields",@"observed") isEqual:@"10"] &&
            [fieldValue(rows[0],@"coreFields",@"checkTime") isEqual:fieldValue(oldNice,@"coreFields",@"checkTime")] &&
            [fieldValue(rows[0],@"coreFields",@"readTime") isEqual:fieldValue(oldNice,@"coreFields",@"readTime")] &&
            [rows[0][@"timestamp"] isEqual:oldNice[@"timestamp"]]);
        REQ("nice-local-pending-no-new-observation", [rows[0][@"state"] isEqual:oldNice[@"state"]] &&
            [fieldValue(rows[0],@"diagnosticFields",@"localPending") isEqual:@"Yes"] && contains(fieldValue(rows[0],@"coreFields",@"policyNote"),@"Earlier readbacks and times remain unchanged"));
        NSDictionary *unavailable=@{@"settingsAvailable":@NO,@"configurationValid":@NO};
        rows=VDTCheckResultModels(unavailable,nice,unavailable,unavailable,base,nil); checkShape(rows);
        for (NSDictionary *row in rows) {
            REQ("saved-settings-unavailable", [row[@"compactState"] isEqual:@"Saved settings unavailable"] && [row[@"compactTone"] isEqual:@"neutral"]);
            REQ("saved-settings-not-invented-off", [fieldValue(row,@"coreFields",@"target") isEqual:@"Saved settings unavailable"] && ![row[@"state"] isEqual:@"Nice state disabled"]);
        }
        REQ("saved-settings-keep-history", [fieldValue(rows[0],@"coreFields",@"observed") isEqual:@"10"] &&
            [fieldValue(rows[1],@"coreFields",@"observed") isEqual:@"64 / 128 MiB"] && [rows[0][@"timestamp"] isEqual:oldNice[@"timestamp"]]);
        batch=countedReceipt(base,allConfirmed,nil); batch[@"configurationValid"]=@NO; rows=project(nice,nil,nil,batch);
        REQ("invalid-configuration-no-summary-success", [rows[1][@"compactState"] isEqual:@"Not confirmed"] &&
            [fieldValue(rows[1],@"coreFields",@"observed") isEqual:@"64 / 128 MiB"] && [fieldValue(rows[1],@"diagnosticFields",@"summaryConfirmed") isEqual:@"Not recorded"]);
        batch=countedReceipt(base,allConfirmed,nil); batch[@"configurationValid"]=@1; rows=project(nice,nil,nil,batch);
        REQ("configuration-boolean-required", [rows[1][@"compactState"] isEqual:@"Not confirmed"]);
        rows=project(nice,@{@"enabled":@NO},nil,base);
        REQ("off-keeps-historical-readback", [rows[1][@"compactState"] isEqual:@"Not enabled"] && [rows[1][@"compactTone"] isEqual:@"neutral"] &&
            [fieldValue(rows[1],@"coreFields",@"observed") isEqual:@"64 / 128 MiB"]);
        rows=project(nice,@{@"enabled":@YES,@"active":@64,@"inactive":@128,@"globallyEnabled":@NO},nil,base);
        REQ("paused-keeps-historical-readback", [rows[1][@"compactState"] isEqual:@"Paused"] && [rows[1][@"compactTone"] isEqual:@"neutral"] &&
            [fieldValue(rows[1],@"coreFields",@"observed") isEqual:@"64 / 128 MiB"]);
        NSMutableDictionary *pausedNice=[nice mutableCopy]; pausedNice[@"state"]=@"paused"; rows=project(pausedNice,nil,nil,base);
        REQ("nice-paused-not-write-failure", [rows[0][@"compactState"] isEqual:@"Paused"] && [rows[0][@"compactTone"] isEqual:@"neutral"] && [fieldValue(rows[0],@"coreFields",@"observed") isEqual:@"10"]);
        rows=VDTCheckResultModels(@{@"requestedEnabled":@NO,@"valid":@YES,@"value":@10},nice,nil,nil,nil,nil); checkShape(rows);
        REQ("nice-off-not-write-failure", [rows[0][@"compactState"] isEqual:@"Not enabled"] && [rows[0][@"compactTone"] isEqual:@"neutral"]);
        rows=project(@{@"state":@"write-failed",@"error":@13,@"pendingCount":@1,@"retryPending":@YES},nil,nil,base);
        REQ("nice-failure", [rows[0][@"tone"] isEqual:@"warning"] && contains(detail(rows[0]),@"errno: 13") && contains(detail(rows[0]),@"Bounded retry pending"));
        rows=project(@{@"state":@"receipt-unavailable",@"error":@(EFBIG),@"receiptUpdatedAt":@1700000000},nil,nil,base);
        checkShape(rows);
        REQ("nice-status-limit", [rows[0][@"state"] isEqual:@"Nice receipt exceeds size limit"] &&
            [rows[0][@"tone"] isEqual:@"warning"] && !contains(rows[0][@"state"],@"write failed"));
        REQ("nice-status-no-old-readback", contains(rows[0][@"summary"],@"Last read back: Not recorded"));
        REQ("nice-status-no-check-time", [rows[0][@"timestamp"] isEqual:@"Check time not recorded"] &&
            [fieldValue(rows[0],@"coreFields",@"checkTime") isEqual:@"Not recorded"] &&
            [fieldValue(rows[0],@"coreFields",@"readTime") isEqual:@"Not recorded"]);
        REQ("nice-status-save-time", [fieldValue(rows[0],@"diagnosticFields",@"receiptTime") isEqual:oldest]);
        REQ("nice-status-no-journal-error", ![rows[0][@"state"] isEqual:@"Nice state store failed"] &&
            ![rows[0][@"scope"] isEqual:@"No verified running instance"]);
        rows=project(@{@"state":@"receipt-unavailable",@"error":@(EIO)},nil,nil,base);
        REQ("nice-status-generic", [rows[0][@"state"] isEqual:@"Nice receipt unavailable"] && [rows[0][@"tone"] isEqual:@"warning"]);
        rows=project(@{@"state":@"receipt-unavailable",@"error":@YES},nil,nil,base);
        REQ("nice-status-bool-not-code", [rows[0][@"state"] isEqual:@"Nice receipt unavailable"]);
        rows=project(nil,nil,nil,@{@"state":@"unsupported",@"memorySkip":@3,@"prioritySkip":@3});
        REQ("policy-vs-backend", [rows[1][@"state"] isEqual:@"Rule not applied"]);
        rows=project(nil,nil,nil,@{@"state":@"unsupported"});
        REQ("backend-unavailable", [rows[1][@"state"] isEqual:@"Write backend unavailable"]);
        rows=project(nil,nil,nil,@{@"state":@"store-error",@"storeError":@22});
        REQ("store-error", [rows[1][@"state"] isEqual:@"Resource journal unavailable"] && contains(detail(rows[1]),@"Storage errno: 22"));
        rows=project(nil,nil,nil,@{@"state":@"write-disabled",@"memorySkip":@1,@"prioritySkip":@1});
        REQ("paused", [rows[1][@"state"] isEqual:@"Resource rules are paused"]);
        for (id malformed in @[[NSNull null],@[],@"not a dictionary",@42]) {
            rows=VDTCheckResultModels(malformed,malformed,malformed,malformed,malformed,nil);
            checkShape(rows); REQ("malformed-not-success", ![rows[1][@"tone"] isEqual:@"ok"]);
        }
        changed=[base mutableCopy]; changed[@"state"]=@[]; changed[@"memory"]=@[];
        changed[@"memorySkip"]=@YES; changed[@"priorityObserved"]=@YES; changed[@"checkedAt"]=@YES;
        changed[@"memoryObserved"]=@[@64,@1]; rows=project(nice,nil,nil,changed);
        REQ("malformed-fields", [rows[1][@"state"] isEqual:@"Side result not recorded"] && contains(rows[2][@"summary"],@"Not recorded"));
        REQ("bool-not-time", [rows[1][@"timestamp"] isEqual:@"Check time not recorded"]);
        rows=VDTCheckResultModels(@{@"requestedEnabled":@YES,@"valid":@YES,@"value":@(UINT32_MAX)},nice,nil,nil,nil,nil);
        REQ("no-integer-narrowing", contains(rows[0][@"summary"],@"Incomplete settings"));
        rows=project(@{@"state":@"applied",@"current":@10},nil,nil,base);
        REQ("current-is-not-history", contains(rows[0][@"summary"],@"Last read back: Not recorded"));
        rows=VDTCheckResultModels(nil,nil,nil,nil,nil,^NSString *(NSString *key) { return [@"L:" stringByAppendingString:key]; });
        REQ("localization", [rows[1][@"title"] isEqual:@"L:Memory"] && contains(rows[1][@"summary"],@"L:Saved target (active / inactive):"));
        printf("PASS check-result model: %u checks; Foundation only, no UIKit or device IO\n",checks);
    }
    return 0;
}
