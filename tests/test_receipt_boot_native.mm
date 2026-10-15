// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
// Real Foundation readers + real root-owned atomic store; only sysctl is fake.
#import "../VDTNiceShared.h"
#import "../VDTResourceShared.h"
#import "../VDTNiceStore.h"
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <notify.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void check(BOOL okay, const char *marker) {
    if (!okay) { fprintf(stderr, "RECEIPT_BOOT_ASSERT:%s\n", marker); abort(); }
}
static NSString *testRoot;
NSString *VDTTestJbroot(NSString *path) {
    check(testRoot && [path hasPrefix:@"/"], "isolated-jbroot");
    return [testRoot stringByAppendingString:path];
}
static const char *uuidA = "12345678-1234-4ABC-8DEF-123456789ABC";
static const char *uuidB = "87654321-4321-4ABC-8DEF-CBA987654321";
static char uuidBytes[64];
static size_t uuidLength;
static BOOL uuidFails, tokenFails;
static struct timeval bootTime;
static void resetKernel(void) {
    memset(uuidBytes, 0, sizeof(uuidBytes)); memcpy(uuidBytes, uuidA, 37);
    uuidLength = 37; uuidFails = tokenFails = NO;
    bootTime.tv_sec = 1000000; bootTime.tv_usec = 20;
}
static int fixtureSysctl(const char *name, void *out, size_t *length, void *newp, size_t newlen) {
    check(out && length && !newp && !newlen, "read-only-sysctl");
    if (!strcmp(name, "kern.boottime")) {
        if (tokenFails) { errno = EIO; return -1; }
        check(*length >= sizeof(bootTime), "boottime-buffer");
        memcpy(out, &bootTime, sizeof(bootTime)); *length = sizeof(bootTime); return 0;
    }
    check(!strcmp(name, "kern.bootsessionuuid"), "no-other-kernel-query");
    if (uuidFails) { errno = EIO; return -1; }
    size_t copy = *length < uuidLength ? *length : uuidLength;
    check(copy <= sizeof(uuidBytes), "uuid-fixture-buffer");
    memcpy(out, uuidBytes, copy); *length = uuidLength; return 0;
}
static uint32_t fixtureNotify(const char *name) {
    (void)name; check(NO, "no-notification"); return 0;
}
#define sysctlbyname fixtureSysctl
#define notify_post fixtureNotify
#ifndef VDT_RECEIPT_NICE_FILE
#define VDT_RECEIPT_NICE_FILE "../VDTNiceShared.mm"
#endif
#ifndef VDT_RECEIPT_RESOURCE_FILE
#define VDT_RECEIPT_RESOURCE_FILE "../VDTResourceShared.mm"
#endif
#include VDT_RECEIPT_NICE_FILE
#include VDT_RECEIPT_RESOURCE_FILE
#undef notify_post
#undef sysctlbyname

static NSString *const identifier = @"receipt-fixture";
static NSDictionary *preferences(NSString *revision, int active) {
    return @{@"enabled": @YES, @"daemonConfigs": @[@{@"daemonName": identifier,
        @"niceEnabled": @YES, @"niceValue": @5, @"niceRevision": revision}],
        @"memoryRules": @[@{@"daemonName": identifier, @"enabled": @YES,
            @"schema": @1, @"active": @(active), @"inactive": @512}]};
}
static NSDictionary *niceReceipt(NSDictionary *prefs) {
    NSMutableDictionary *row = [VDTNiceEffectiveRule(identifier, VDTConfigTypeDaemon, nil, prefs) mutableCopy];
    [row addEntriesFromDictionary:@{@"state": @"applied", @"observed": @5, @"checkedAt": @123,
        @"targetCount": @1, @"appliedCount": @1, @"pendingCount": @0, @"error": @0}];
    return @{@"version": @1, @"boot": @"1000000:20", @"updatedAt": @123,
        @"rules": @{VDTNiceRuleKey(VDTConfigTypeDaemon, identifier): row}};
}
static NSDictionary *resourceReceipt(NSDictionary *prefs) {
    NSDictionary *row = @{@"state": @"applied", @"checkedAt": @123, @"memory": @"applied",
        @"memoryObserved": @[@256, @0, @512, @0], @"memoryObservedAt": @123};
    return @{@"version": @1, @"boot": @"1000000:20", @"storeError": @0,
        @"configuration": VDTResourceConfiguration(prefs),
        @"rows": @{VDTNiceRuleKey(VDTConfigTypeDaemon, identifier): row}};
}
static NSDictionary *field(NSDictionary *raw, NSString *key, id value) {
    NSMutableDictionary *result = [raw mutableCopy];
    if (value) result[key] = value; else [result removeObjectForKey:key];
    return result;
}
static NSString *statusPath(BOOL resource) {
    return [(resource ? VDTResourceStateDirectory() : VDTNiceStateDirectory())
        stringByAppendingPathComponent:@VDT_NICE_STATUS];
}
static void writeReceipt(BOOL resource, NSDictionary *receipt) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:receipt
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    check(data && data.length <= VDT_NICE_STORE_LIMIT, "serialize-real-receipt");
    VDTNiceStore store;
    check(!VDTNiceStoreOpen((resource ? VDTResourceStateDirectory() : VDTNiceStateDirectory()).fileSystemRepresentation,
        1, &store), "root-owned-store-open");
    int error = VDTNiceStoreWrite(&store, VDT_NICE_STATUS, data.bytes, data.length);
    VDTNiceStoreClose(&store); check(!error, "real-store-write");
}
static NSDictionary *readReceipt(BOOL resource, NSDictionary *prefs) {
    return resource ? VDTResourceMatchingStatus(identifier, VDTConfigTypeDaemon, prefs) :
        VDTNiceMatchingStatus(identifier, VDTConfigTypeDaemon, prefs);
}
static void writeBoth(NSDictionary *nice, NSDictionary *resource) {
    writeReceipt(NO, nice); writeReceipt(YES, resource);
}
static void rejected(NSDictionary *prefs, const char *marker) {
    check(!readReceipt(NO, prefs), marker); check(!readReceipt(YES, prefs), marker);
}
static void readouts(NSDictionary *prefs, const char *marker) {
    NSDictionary *nice = readReceipt(NO, prefs), *resource = readReceipt(YES, prefs);
    check([nice[@"state"] isEqual:@"applied"] && [nice[@"observed"] isEqual:@5] &&
        [nice[@"checkedAt"] isEqual:@123] && [nice[@"appliedCount"] isEqual:@1], marker);
    check([resource[@"state"] isEqual:@"applied"] && [resource[@"memoryObserved"] isEqual:@[@256, @0, @512, @0]] &&
        [resource[@"checkedAt"] isEqual:@123], marker);
}
static void unchangedRead(NSDictionary *prefs, BOOL accepted) {
    for (unsigned i = 0; i < 2; ++i) {
        BOOL resource = i != 0; NSString *path = statusPath(resource);
        NSData *before = [NSData dataWithContentsOfFile:path]; struct stat a, b;
        check(!lstat(path.fileSystemRepresentation, &a), "legacy-stat-before");
        check((readReceipt(resource, prefs) != nil) == accepted, "legacy-read-result");
        check(!lstat(path.fileSystemRepresentation, &b), "legacy-stat-after");
        check([before isEqual:[NSData dataWithContentsOfFile:path]] && a.st_ino == b.st_ino &&
            a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_uid == b.st_uid &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec,
            "legacy-read-does-not-rewrite");
    }
}

int main(void) {
    @autoreleasepool {
        check(geteuid() == 0, "requires-root");
        const char *root = getenv("VDT_RECEIPT_BOOT_TEST_ROOT");
        check(root && root[0] == '/', "requires-isolated-root");
        testRoot = [NSString stringWithUTF8String:root];
        check([NSFileManager.defaultManager createDirectoryAtPath:[testRoot stringByAppendingString:@"/var/tmp"]
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:NULL], "isolated-parent");
        resetKernel();
        NSDictionary *prefs = preferences(@"r1", 256);
        NSDictionary *oldNice = niceReceipt(prefs), *oldResource = resourceReceipt(prefs);
        NSDictionary *nice = VDTNiceReceiptWithBootSession(oldNice);
        NSDictionary *resource = VDTNiceReceiptWithBootSession(oldResource);
        check([nice[@"bootSession"] isEqual:@(uuidA)] && [resource[@"bootSession"] isEqual:@(uuidA)],
            "writer-attaches-session");
        check(!oldNice[@"bootSession"] && !oldResource[@"bootSession"], "writer-does-not-mutate-input");
        writeBoth(nice, resource);
        ++bootTime.tv_sec; bootTime.tv_usec += 9;
        readouts(prefs, "same-session-different-boottime");
        resetKernel(); memcpy(uuidBytes, uuidB, 37);
        rejected(prefs, "foreign-session-same-legacy-rejected");
        resetKernel();
        for (id invalid in @[@"", @17, @YES, @[], @{}, @"not-a-uuid",
            [@(uuidA) stringByAppendingString:@"extra"], [@(uuidA) lowercaseString]]) {
            writeBoth(field(nice, @"bootSession", invalid), field(resource, @"bootSession", invalid));
            rejected(prefs, "invalid-session-no-legacy-fallback");
        }
        writeBoth(nice, resource); uuidFails = YES;
        rejected(prefs, "query-failure-no-legacy-fallback");
        NSDictionary *fallbackNice = VDTNiceReceiptWithBootSession(oldNice);
        NSDictionary *fallbackResource = VDTNiceReceiptWithBootSession(oldResource);
        check(!fallbackNice[@"bootSession"] && [fallbackNice isEqual:oldNice] &&
            !fallbackResource[@"bootSession"] && [fallbackResource isEqual:oldResource], "writer-legacy-on-query-failure");
        writeBoth(fallbackNice, fallbackResource); readouts(prefs, "writer-legacy-still-readable");
        ++bootTime.tv_usec; rejected(prefs, "writer-legacy-remains-exact");

        // Bad kernel ABI responses: wrong length, missing/embedded NUL, bad UUID.
        for (unsigned bad = 0; bad < 8; ++bad) {
            resetKernel();
            if (bad == 0) uuidLength = 0;
            if (bad == 1) uuidLength = 36;
            if (bad == 2) uuidLength = 38;
            if (bad == 3) uuidBytes[36] = 'X';
            if (bad == 4) uuidBytes[5] = '\0';
            if (bad == 5) uuidBytes[0] = 'G';
            if (bad == 6) uuidBytes[8] = 'A';
            if (bad == 7) uuidBytes[0] = (char)0xff;
            writeBoth(nice, resource); rejected(prefs, "invalid-kernel-uuid-no-fallback");
            check(!VDTNiceReceiptWithBootSession(oldNice)[@"bootSession"] &&
                !VDTNiceReceiptWithBootSession(oldResource)[@"bootSession"], "invalid-kernel-uuid-not-published");
        }
        resetKernel(); writeBoth(oldNice, oldResource);
        readouts(prefs, "legacy-exact-match"); unchangedRead(prefs, YES);
        ++bootTime.tv_sec; rejected(prefs, "legacy-different-seconds"); unchangedRead(prefs, NO);
        resetKernel(); ++bootTime.tv_usec; rejected(prefs, "legacy-different-microseconds");
        resetKernel();
        for (id invalid in @[@"", @123, @"1000000:020", @"01000000:20", @"1000000:20suffix"]) {
            writeBoth(field(oldNice, @"boot", invalid), field(oldResource, @"boot", invalid));
            rejected(prefs, "legacy-strict-string-match");
        }
        writeBoth(field(oldNice, @"boot", nil), field(oldResource, @"boot", nil));
        rejected(prefs, "legacy-missing-token");
        writeBoth(oldNice, oldResource); tokenFails = YES;
        rejected(prefs, "legacy-query-failure");
        // UUID, not the obsolete timeval query, authorizes a new receipt read.
        writeBoth(VDTNiceReceiptWithBootSession(field(oldNice, @"boot", nil)),
            VDTNiceReceiptWithBootSession(field(oldResource, @"boot", nil)));
        readouts(prefs, "uuid-readable-without-legacy-token");

        resetKernel(); writeBoth(nice, resource);
        check(!readReceipt(NO, preferences(@"r2", 256)), "nice-revision-still-checked");
        check(!readReceipt(YES, preferences(@"r1", 257)), "resource-configuration-still-checked");
        NSDictionary *niceError = VDTNiceReceiptWithBootSession(@{@"version": @1, @"boot": @"1000000:20",
            @"statusError": @(EFBIG), @"updatedAt": @123, @"rules": nice[@"rules"]});
        NSDictionary *resourceError = VDTNiceReceiptWithBootSession(field(oldResource, @"storeError", @(EIO)));
        writeBoth(niceError, resourceError); ++bootTime.tv_usec;
        NSDictionary *nr = readReceipt(NO, prefs), *rr = readReceipt(YES, prefs);
        check([nr[@"state"] isEqual:@"receipt-unavailable"] && [nr[@"error"] isEqual:@(EFBIG)] &&
            [nr[@"receiptUpdatedAt"] isEqual:@123] && nr.count == 3 && !nr[@"checkedAt"] && !nr[@"observed"],
            "same-session-status-error-not-success");
        check([rr[@"state"] isEqual:@"store-error"] && [rr[@"storeError"] isEqual:@(EIO)] &&
            rr.count == 2 && !rr[@"checkedAt"] && !rr[@"memoryObserved"], "same-session-store-error-not-success");
        resetKernel(); memcpy(uuidBytes, uuidB, 37);
        rejected(prefs, "foreign-session-error-envelope-rejected");
        resetKernel(); uuidFails = YES;
        rejected(prefs, "query-failure-error-envelope-rejected");
        puts("PASS native receipt boot readers/store");
    }
    return 0;
}
