// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
// Real Reader + Model with in-memory read stubs. No plist, process or kernel IO.
// Darwin provenance is fixture data; mock receipts do not simulate OS eligibility.
#import "../vedetteprefs/VDTCheckResultReader.h"
#import "../VDTNiceShared.h"
#import "../VDTResourceShared.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define REQ(tag, ...) do { ++checks; if (!(__VA_ARGS__)) { \
    fprintf(stderr, "CHECK_READER_FAIL:%s line %d\n", tag, __LINE__); abort(); \
} } while (0)

static NSString *const identifier = @"com.example.reader-test";
static NSString *fixtureIdentifier;
static NSString *fixtureHost;
static VDTConfigType fixtureType = VDTConfigTypeApp;
static NSDictionary *fixturePrefs;
static NSDictionary *fixtureNiceRule;
static NSDictionary *fixtureNiceReceipt;
static NSDictionary *fixtureResourceReceipt;
static unsigned preferenceReads, niceRuleReads, niceReceiptReads, resourceReceiptReads;
static unsigned resourceNilSnapshotReads, resourceRuleReads, resourceHostReads;
static unsigned hostMemoryReads, hostPriorityReads;

// These definitions use the exact C declarations imported from production
// headers. Only the persistence/status boundaries are replaced, not Reader or
// Model. Successful receipts may be injected even for invalid or unavailable
// settings: that is adversarial input, not an implementation of receipt matching.
NSDictionary *VDTResourceReadPreferences(void) {
    ++preferenceReads;
    return fixturePrefs;
}

NSString *VDTNiceRuleKey(VDTConfigType type, NSString *name) {
    if ((type != VDTConfigTypeApp && type != VDTConfigTypeDaemon && type != VDTConfigTypeExtension) ||
        ![name isKindOfClass:NSString.class] || !name.length) return nil;
    return [NSString stringWithFormat:@"%lu:%@", (unsigned long)type, name];
}

static BOOL sameHost(NSString *host) {
    return host == fixtureHost || [host isEqual:fixtureHost];
}

NSDictionary *VDTNiceEffectiveRule(NSString *name, VDTConfigType type, NSString *host, NSDictionary *prefs) {
    REQ("nice-rule-snapshot", [name isEqual:fixtureIdentifier] && type == fixtureType && sameHost(host) && prefs == fixturePrefs);
    ++niceRuleReads;
    return fixtureNiceRule;
}

NSDictionary *VDTNiceMatchingStatusWithHost(NSString *name, VDTConfigType type, NSString *host, NSDictionary *prefs) {
    REQ("nice-receipt-snapshot", [name isEqual:fixtureIdentifier] && type == fixtureType && sameHost(host) && prefs == fixturePrefs);
    ++niceReceiptReads;
    return fixtureNiceReceipt;
}

static NSDictionary *resourceEntry(NSString *name, VDTConfigType type, NSString *section, NSDictionary *prefs) {
    ++resourceRuleReads;
    REQ("resource-snapshot", prefs && prefs == fixturePrefs);
    BOOL own = type == fixtureType && [name isEqual:fixtureIdentifier];
    BOOL host = fixtureType == VDTConfigTypeExtension && type == VDTConfigTypeApp && [name isEqual:fixtureHost];
    REQ("resource-identity", own || host);
    if (host) {
        ++resourceHostReads;
        if ([section isEqual:@"memoryRules"]) ++hostMemoryReads;
        if ([section isEqual:@"jetsamRules"]) ++hostPriorityReads;
    }
    NSString *key = type == VDTConfigTypeApp ? @"bundleIdentifier" :
        type == VDTConfigTypeDaemon ? @"daemonName" : @"extensionIdentifier";
    if (![prefs[section] isKindOfClass:NSArray.class]) return nil;
    for (id item in prefs[section]) {
        if ([item isKindOfClass:NSDictionary.class] && [item[key] isEqual:name]) return item;
    }
    return nil;
}

BOOL VDTHasProcessResourceRule(NSString *name, VDTConfigType type, NSString *section, NSDictionary *prefs) {
    return resourceEntry(name, type, section, prefs) != nil;
}

id valueForProcessResourceRuleKeyWithPrefs(NSString *name, NSString *key, id fallback,
    VDTConfigType type, NSString *section, NSDictionary *prefs) {
    return resourceEntry(name, type, section, prefs)[key] ?: fallback;
}

NSDictionary *VDTResourceMatchingStatus(NSString *name, VDTConfigType type, NSDictionary *prefs) {
    REQ("resource-receipt-snapshot", [name isEqual:fixtureIdentifier] && type == fixtureType && prefs == fixturePrefs);
    ++resourceReceiptReads;
    if (!prefs) ++resourceNilSnapshotReads;
    return fixtureResourceReceipt;
}

static NSString *field(NSDictionary *row, NSString *collection, NSString *name) {
    for (NSDictionary *entry in row[collection]) if ([entry[@"id"] isEqual:name]) return entry[@"value"];
    return nil;
}

static BOOL contains(NSString *text, NSString *fragment) {
    return [text isKindOfClass:NSString.class] && [text rangeOfString:fragment].location != NSNotFound;
}

static BOOL isBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSDictionary *binaryRoundTrip(NSDictionary *value) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    REQ("plist-serialize", data != nil);
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    id restored = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:&format error:NULL];
    REQ("plist-deserialize", [restored isKindOfClass:NSDictionary.class] && format == NSPropertyListBinaryFormat_v1_0);
    return restored;
}

static NSArray *readRows(void) {
    unsigned beforePrefs = preferenceReads, beforeNiceRule = niceRuleReads;
    unsigned beforeNiceReceipt = niceReceiptReads, beforeResourceReceipt = resourceReceiptReads;
    unsigned beforeNilReceipt = resourceNilSnapshotReads, beforeRules = resourceRuleReads;
    NSMutableDictionary *context = [@{@"type": @(fixtureType), @"identifier": fixtureIdentifier} mutableCopy];
    if (fixtureHost) context[@"host"] = fixtureHost;
    NSArray *rows = VDTReadCheckResultModels(context, NO, nil);
    REQ("single-preference-snapshot", preferenceReads == beforePrefs + 1);
    REQ("nice-uses-snapshot", niceRuleReads == beforeNiceRule + (fixturePrefs ? 1u : 0u) &&
        niceReceiptReads == beforeNiceReceipt + (fixturePrefs ? 1u : 0u));
    REQ("resource-uses-snapshot", resourceReceiptReads == beforeResourceReceipt + 1);
    REQ("resource-nil-snapshot", resourceNilSnapshotReads == beforeNilReceipt + (fixturePrefs ? 0u : 1u));
    REQ("no-resource-rule-read-without-snapshot", fixturePrefs || resourceRuleReads == beforeRules);
    REQ("three-rows", rows.count == 3 && [rows[0][@"title"] isEqual:@"nice"] &&
        [rows[1][@"title"] isEqual:@"Memory"] && [rows[2][@"title"] isEqual:@"Reclaim priority"]);
    return rows;
}

static void checkNotConfirmed(NSDictionary *row) {
    REQ("bad-settings-not-confirmed", ![row[@"compactTone"] isEqual:@"ok"] &&
        !contains(row[@"compactState"], @"Confirmed"));
}

static NSDictionary *validPrefs(void) {
    return @{@"enabled": @YES,
        @"appConfigs": @[@{@"bundleIdentifier": identifier, @"niceEnabled": @YES, @"niceValue": @5}],
        @"memoryRules": @[@{@"bundleIdentifier": identifier, @"schema": @1, @"enabled": @YES,
                            @"active": @64, @"inactive": @128}],
        @"jetsamRules": @[@{@"bundleIdentifier": identifier, @"schema": @1, @"enabled": @YES,
                            @"priority": @10, @"sourceDarwinMajor": @21}]};
}

static void setUpReceipts(NSDictionary *prefs) {
    NSDictionary *nice = prefs[@"appConfigs"][0];
    fixtureNiceRule = binaryRoundTrip(@{@"identifier": identifier, @"type": @(VDTConfigTypeApp), @"present": @YES,
        @"requestedEnabled": nice[@"niceEnabled"], @"enabled": @YES, @"valid": @YES,
        @"value": nice[@"niceValue"], @"revision": @""});
    fixtureNiceReceipt = binaryRoundTrip(@{@"state": @"applied", @"evidence": @"matched-without-set", @"observed": @5,
        @"original": @0, @"error": @0, @"targetCount": @1, @"pendingCount": @0,
        @"checkedAt": @1700000000, @"observedAt": @1700000000});
    NSDictionary *summary = @{@"version": @1, @"batch": @1, @"scope": @"identified-targets",
        @"enumerationComplete": @YES, @"total": @1, @"applied": @1, @"restored": @0,
        @"failed": @0, @"pending": @0, @"unknown": @0, @"disabled": @0};
    fixtureResourceReceipt = binaryRoundTrip(@{@"state": @"applied", @"memory": @"applied", @"priority": @"applied",
        @"memoryEvidence": @"matched-without-set", @"priorityEvidence": @"matched-without-set",
        @"memoryObserved": @[@64, @1, @128, @1], @"priorityObserved": @10,
        @"checkedAt": @1700000000, @"memoryObservedAt": @1700000000, @"priorityObservedAt": @1700000000,
        @"pid": @42, @"instanceCount": @1, @"checkBatch": @1,
        @"summaries": @{@"memory": summary, @"priority": summary},
        @"latestCheck": @{@"version": @1, @"batch": @1, @"enumerationComplete": @YES,
                          @"error": @0, @"attemptedAt": @1700000000}});
}

static void setScenarioReceipts(NSDictionary *sourceNice, VDTConfigType sourceType, NSString *sourceIdentifier,
    NSNumber *active, NSNumber *inactive, NSNumber *priority) {
    // The real nice resolver is stubbed; Reader must pass it the right identity
    // and host. Resource inheritance itself is exercised by real Reader code.
    NSMutableDictionary *rule = [fixtureNiceRule mutableCopy];
    rule[@"identifier"] = fixtureIdentifier; rule[@"type"] = @(fixtureType);
    rule[@"value"] = sourceNice[@"niceValue"]; rule[@"requestedEnabled"] = sourceNice[@"niceEnabled"];
    rule[@"sourceIdentifier"] = sourceIdentifier; rule[@"sourceType"] = @(sourceType);
    rule[@"inherited"] = sourceType != fixtureType ? @YES : @NO;
    fixtureNiceRule = binaryRoundTrip(rule);
    NSMutableDictionary *nice = [fixtureNiceReceipt mutableCopy]; nice[@"observed"] = sourceNice[@"niceValue"];
    fixtureNiceReceipt = binaryRoundTrip(nice);
    NSMutableDictionary *resource = [fixtureResourceReceipt mutableCopy];
    resource[@"memoryObserved"] = @[active, @1, inactive, @1]; resource[@"priorityObserved"] = priority;
    fixtureResourceReceipt = binaryRoundTrip(resource);
}

static void checkScenario(const char *tag, NSArray *rows, NSArray *targets) {
    for (NSUInteger index = 0; index < rows.count; ++index) {
        REQ(tag, [rows[index][@"compactState"] isEqual:@"Confirmed"] && [rows[index][@"compactTone"] isEqual:@"ok"] &&
            [field(rows[index], @"coreFields", @"target") isEqual:targets[index]] &&
            [field(rows[index], @"coreFields", @"observed") isEqual:targets[index]]);
    }
    for (NSUInteger index = 1; index < rows.count; ++index)
        REQ(tag, contains(field(rows[index], @"coreFields", @"coverage"), @"Confirmed 1/1"));
}

static void checkOtherIdentities(void) {
    NSString *daemon = @"com.example.reader-daemon", *extension = @"com.example.reader-extension";
    NSString *host = @"com.example.reader-host";
    NSDictionary *prefs = binaryRoundTrip(@{@"enabled": @YES,
        @"daemonConfigs": @[@{@"daemonName": daemon, @"niceEnabled": @YES, @"niceValue": @5}],
        @"extensionConfigs": @[@{@"extensionIdentifier": extension, @"niceEnabled": @YES, @"niceValue": @5}],
        @"appConfigs": @[@{@"bundleIdentifier": host, @"niceEnabled": @YES, @"niceValue": @(-3)}],
        @"memoryRules": @[@{@"daemonName": daemon, @"schema": @1, @"enabled": @YES, @"active": @32, @"inactive": @96},
                          @{@"extensionIdentifier": extension, @"schema": @1, @"enabled": @YES, @"active": @64, @"inactive": @128},
                          @{@"bundleIdentifier": host, @"schema": @1, @"enabled": @YES, @"active": @256, @"inactive": @512}],
        @"jetsamRules": @[@{@"daemonName": daemon, @"schema": @1, @"enabled": @YES, @"priority": @6, @"sourceDarwinMajor": @21},
                          @{@"extensionIdentifier": extension, @"schema": @1, @"enabled": @YES, @"priority": @10, @"sourceDarwinMajor": @21},
                          @{@"bundleIdentifier": host, @"schema": @1, @"enabled": @YES, @"priority": @12, @"sourceDarwinMajor": @21}]});
    fixturePrefs = prefs; fixtureType = VDTConfigTypeDaemon; fixtureIdentifier = daemon; fixtureHost = nil;
    setScenarioReceipts(prefs[@"daemonConfigs"][0], VDTConfigTypeDaemon, daemon, @32, @96, @6);
    checkScenario("daemon-direct", readRows(), @[@"5", @"32 / 96 MiB", @"6"]);

    fixtureType = VDTConfigTypeExtension; fixtureIdentifier = extension; fixtureHost = host;
    setScenarioReceipts(prefs[@"extensionConfigs"][0], VDTConfigTypeExtension, extension, @64, @128, @10);
    unsigned beforeHost = resourceHostReads;
    checkScenario("extension-direct", readRows(), @[@"5", @"64 / 128 MiB", @"10"]);
    REQ("extension-own-blocks-host", resourceHostReads == beforeHost);

    NSMutableDictionary *inherited = [prefs mutableCopy];
    inherited[@"extensionConfigs"] = @[];
    inherited[@"memoryRules"] = @[prefs[@"memoryRules"][0], prefs[@"memoryRules"][2]];
    inherited[@"jetsamRules"] = @[prefs[@"jetsamRules"][0], prefs[@"jetsamRules"][2]];
    fixturePrefs = binaryRoundTrip(inherited);
    setScenarioReceipts(fixturePrefs[@"appConfigs"][0], VDTConfigTypeApp, host, @256, @512, @12);
    unsigned beforeMemory = hostMemoryReads, beforePriority = hostPriorityReads;
    checkScenario("extension-host", readRows(), @[@"-3", @"256 / 512 MiB", @"12"]);
    REQ("extension-host-resource-lookups", hostMemoryReads > beforeMemory && hostPriorityReads > beforePriority);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *types = binaryRoundTrip(@{@"true": @YES, @"false": @NO, @"one": @1, @"zero": @0});
        REQ("plist-true-boolean", isBoolean(types[@"true"]) && [types[@"true"] boolValue]);
        REQ("plist-false-boolean", isBoolean(types[@"false"]) && ![types[@"false"] boolValue]);
        REQ("plist-one-integer", [types[@"one"] isKindOfClass:NSNumber.class] &&
            !isBoolean(types[@"one"]) && [types[@"one"] intValue] == 1);
        REQ("plist-zero-integer", [types[@"zero"] isKindOfClass:NSNumber.class] &&
            !isBoolean(types[@"zero"]) && [types[@"zero"] intValue] == 0);
        fixtureIdentifier = identifier;
        NSDictionary *valid = binaryRoundTrip(validPrefs());
        REQ("prefs-boolean-roundtrip", isBoolean(valid[@"enabled"]) &&
            isBoolean(valid[@"appConfigs"][0][@"niceEnabled"]) &&
            isBoolean(valid[@"memoryRules"][0][@"enabled"]) && isBoolean(valid[@"jetsamRules"][0][@"enabled"]));
        setUpReceipts(valid);
        NSDictionary *summary = fixtureResourceReceipt[@"summaries"][@"priority"];
        REQ("receipt-boolean-roundtrip", isBoolean(summary[@"enumerationComplete"]) &&
            isBoolean(fixtureResourceReceipt[@"latestCheck"][@"enumerationComplete"]));
        REQ("receipt-one-is-integer", !isBoolean(summary[@"version"]) && !isBoolean(summary[@"batch"]) &&
            !isBoolean(summary[@"total"]) && !isBoolean(summary[@"applied"]) &&
            !isBoolean(fixtureResourceReceipt[@"checkBatch"]) && [summary[@"batch"] intValue] == 1);
        fixturePrefs = valid;
        NSArray *rows = readRows();
        for (NSDictionary *row in rows) {
            // The old @(available && ...) boxes an int on Apple clang. This
            // exact marker must kill the compiled mutation, not a build error.
            REQ("valid-configuration", ![row[@"state"] isEqual:@"Incomplete settings"] &&
                [field(row, @"diagnosticFields", @"configurationValid") isEqual:@"Yes"]);
            REQ("matched-receipt", [row[@"state"] isEqual:@"Readback matches; no write needed"] &&
                [row[@"compactState"] isEqual:@"Confirmed"] && [row[@"compactTone"] isEqual:@"ok"]);
            REQ("matched-evidence", [field(row, @"diagnosticFields", @"evidence") isEqual:@"matched-without-set"]);
        }
        NSArray *targets = @[@"5", @"64 / 128 MiB", @"10"];
        for (NSUInteger index = 0; index < rows.count; ++index) {
            REQ("target-value", [field(rows[index], @"coreFields", @"target") isEqual:targets[index]]);
            REQ("observed-value", [field(rows[index], @"coreFields", @"observed") isEqual:targets[index]]);
        }
        for (NSUInteger index = 1; index < rows.count; ++index) {
            REQ("single-summary-coverage", contains(field(rows[index], @"coreFields", @"coverage"), @"Confirmed 1/1"));
            REQ("single-summary-counts", [field(rows[index], @"diagnosticFields", @"summaryConfirmed") isEqual:@"1"] &&
                [field(rows[index], @"diagnosticFields", @"summaryTotal") isEqual:@"1"]);
        }

        // A serialized BOOL false is valid, unlike the serialized integer zero.
        NSMutableDictionary *paused = [valid mutableCopy]; paused[@"enabled"] = @NO;
        fixturePrefs = binaryRoundTrip(paused);
        REQ("saved-false-remains-boolean", isBoolean(fixturePrefs[@"enabled"]) && ![fixturePrefs[@"enabled"] boolValue]);
        NSDictionary *savedResourceReceipt = fixtureResourceReceipt;
        fixtureResourceReceipt = nil;
        rows = readRows();
        for (NSDictionary *row in rows) {
            REQ("false-global-valid-paused", [field(row, @"diagnosticFields", @"configurationValid") isEqual:@"Yes"] &&
                [row[@"compactState"] isEqual:@"Paused"] && ![row[@"compactTone"] isEqual:@"ok"]);
        }

        fixturePrefs = nil;
        rows = readRows();
        for (NSDictionary *row in rows) {
            REQ("missing-prefs-no-receipt", [row[@"state"] isEqual:@"Saved settings unavailable"] &&
                [field(row, @"coreFields", @"target") isEqual:@"Saved settings unavailable"]);
            checkNotConfirmed(row);
        }
        REQ("missing-prefs-no-resource-history", [field(rows[2], @"coreFields", @"observed") isEqual:@"Not recorded"]);
        // A non-nil result is also possible from the status boundary; inject it
        // adversarially and verify it cannot turn unknown settings into success.
        fixtureResourceReceipt = savedResourceReceipt;
        rows = readRows();
        for (NSDictionary *row in rows) {
            REQ("missing-prefs-unavailable", [row[@"state"] isEqual:@"Saved settings unavailable"] &&
                [field(row, @"coreFields", @"target") isEqual:@"Saved settings unavailable"]);
            checkNotConfirmed(row);
        }
        REQ("missing-prefs-retains-resource-history", [field(rows[2], @"coreFields", @"observed") isEqual:@"10"]);

        for (id badGlobal in @[@1, @0, @"YES", @[], @{}]) {
            NSMutableDictionary *bad = [valid mutableCopy]; bad[@"enabled"] = badGlobal;
            fixturePrefs = binaryRoundTrip(bad);
            if ([badGlobal isKindOfClass:NSNumber.class])
                REQ("numeric-global-remains-integer", !isBoolean(fixturePrefs[@"enabled"]) &&
                    [fixturePrefs[@"enabled"] intValue] == [badGlobal intValue]);
            rows = readRows();
            for (NSDictionary *row in rows) {
                REQ("invalid-global", [row[@"state"] isEqual:@"Incomplete settings"] &&
                    [row[@"compactState"] isEqual:@"Not confirmed"] &&
                    [field(row, @"coreFields", @"target") isEqual:@"Incomplete settings"]);
                checkNotConfirmed(row);
            }
            for (NSUInteger index = 1; index < rows.count; ++index)
                REQ("invalid-global-no-counts", [field(rows[index], @"diagnosticFields", @"summaryConfirmed") isEqual:@"Not recorded"]);
        }

        NSArray *sections = @[@"appConfigs", @"memoryRules", @"jetsamRules"];
        for (NSUInteger index = 0; index < sections.count; ++index) {
            for (id badSection in @[@"not-an-array", @[@42]]) {
                NSMutableDictionary *bad = [valid mutableCopy]; bad[sections[index]] = badSection;
                fixturePrefs = binaryRoundTrip(bad); rows = readRows();
                REQ("invalid-section", [rows[index][@"state"] isEqual:@"Incomplete settings"] &&
                    [rows[index][@"compactState"] isEqual:@"Not confirmed"] &&
                    [field(rows[index], @"coreFields", @"target") isEqual:@"Incomplete settings"]);
                checkNotConfirmed(rows[index]);
                for (NSUInteger other = 0; other < rows.count; ++other) {
                    if (other != index)
                        REQ("invalid-section-isolated", [rows[other][@"compactState"] isEqual:@"Confirmed"] &&
                            [rows[other][@"compactTone"] isEqual:@"ok"]);
                }
            }
        }
        checkOtherIdentities();
        printf("PASS check-result Reader + Model: %u checks; in-memory stubs, Foundation only, no device IO\n", checks);
    }
    return 0;
}
