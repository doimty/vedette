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
static NSArray *project(NSDictionary *nice, NSDictionary *memory, NSDictionary *priority, NSDictionary *receipt) {
    return VDTCheckResultModels(@{@"requestedEnabled":@YES,@"valid":@YES,@"value":@10},nice,
        memory ?: @{@"enabled":@YES,@"active":@64,@"inactive":@128},
        priority ?: @{@"enabled":@YES,@"priority":@15},receipt,^NSString *(NSString *key) { return key; });
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
    REQ("three-rows", rows.count == 3);
    REQ("row-order", [rows[0][@"title"] isEqual:@"nice"] && [rows[1][@"title"] isEqual:@"Memory"] && [rows[2][@"title"] isEqual:@"Reclaim priority"]);
    for (NSDictionary *row in rows) {
        for (NSString *key in @[@"title",@"state",@"tone",@"summary",@"timestamp",@"scope"])
            REQ("string-fields", [row[key] isKindOfClass:NSString.class] && [row[key] length] > 0);
        REQ("stable-core-fields", [row[@"coreFields"] count] >= 6 && row[@"details"] == nil);
        for (NSString *collection in @[@"coreFields", @"diagnosticFields"]) {
            NSMutableSet *ids = [NSMutableSet set];
            for (NSDictionary *field in row[collection]) {
                REQ("field-shape", [field[@"value"] isKindOfClass:NSString.class] && [field[@"label"] length] > 0 && [field[@"id"] length] > 0);
                REQ("field-id-unique", ![ids containsObject:field[@"id"]]); [ids addObject:field[@"id"]];
            }
        }
        for (NSString *rawKey in @[@"code", @"errno", @"rawReadback", @"pid"])
            REQ("raw-out-of-core", fieldValue(row,@"coreFields",rawKey) == nil);
    }
}
int main(void) {
    @autoreleasepool {
        NSDictionary *nice = @{@"state":@"applied",@"original":@0,@"observed":@10,@"error":@0,@"pendingCount":@0,@"targetCount":@1,@"checkedAt":@1700000010,@"oldestCheckedAt":@1700000000};
        NSDictionary *base = @{@"state":@"applied",@"memory":@"applied",@"priority":@"applied",@"memorySkip":@0,@"prioritySkip":@0,@"memoryObserved":@[@64,@1,@128,@1],@"priorityObserved":@15,@"checkedAt":@1700000005,@"pid":@42};
        NSArray *rows = project(nice,nil,nil,base); checkShape(rows);
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
        REQ("side-receipt-observed", [rows[2][@"state"] isEqual:@"Changed; not overwritten"] &&
            contains(rows[2][@"summary"], @"Last read back: 21") && contains(detail(rows[2]), @"read-before-conflict"));
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
        REQ("unknown-time", [rows[1][@"timestamp"] isEqual:@"Check time not recorded"]);
        changed=[base mutableCopy]; changed[@"multipleInstances"]=@YES;
        rows=project(nice,nil,nil,changed);
        REQ("representative-only", contains(rows[1][@"scope"],@"selected instance only") && contains(detail(rows[1]),@"Selected PID: 42"));
        NSMutableDictionary *many=[nice mutableCopy]; many[@"targetCount"]=@2;
        rows=project(many,nil,nil,base);
        REQ("nice-no-aggregate-value", contains(rows[0][@"summary"],@"Last read back: Not recorded") && contains(rows[0][@"scope"],@"individual readbacks unavailable"));
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
