// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
// Root-only, one-shot removal handshake. This tool NEVER changes nice itself.
#import "../VDTNiceShared.h"
#import "../VDTNiceStore.h"
#import "../VDTResourceShared.h"
#include <errno.h>
#include <notify.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static NSDictionary *load(VDTNiceStore *store, const char *name, int *error) {
    void *bytes = NULL; size_t length = 0;
    *error = VDTNiceStoreRead(store, name, &bytes, &length);
    if (*error) return nil;
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
    id result = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![result isKindOfClass:NSDictionary.class]) { *error = EINVAL; return nil; }
    return result;
}
static double monotonic(void) {
    struct timespec time = {};
    if (clock_gettime(CLOCK_MONOTONIC, &time)) return -1;
    return (double)time.tv_sec + time.tv_nsec / 1e9;
}
static int restore(VDTNiceStore *store) {
    NSString *boot = VDTNiceBootToken(), *nonce = NSUUID.UUID.UUIDString;
    if (!boot) return ENOTSUP;
    NSData *request = [NSPropertyListSerialization dataWithPropertyList:
        @{@"version": @1, @"boot": boot, @"nonce": nonce} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!request) return EINVAL;
    int error = VDTNiceStoreWrite(store, VDT_NICE_REQUEST, request.bytes, request.length);
    if (error) return error;
    if (notify_post(VDT_NICE_RESTORE_NOTIFICATION) != NOTIFY_STATUS_OK) return EIO;
    double start = monotonic();
    if (start < 0) return EIO;
    // Bounded foreground command, not a resident service or recurring timer.
    for (unsigned attempt = 0; attempt < 100; ++attempt) {
        @autoreleasepool {
            NSDictionary *receipt = load(store, VDT_NICE_STATUS, &error);
            if (!error && [receipt[@"version"] isEqual:@1] && [receipt[@"boot"] isEqual:boot] &&
                [receipt[@"restoreNonce"] isEqual:nonce] && [receipt[@"paused"] isEqual:@YES] &&
                [receipt[@"storeError"] isEqual:@0] && [receipt[@"recordCount"] isEqual:@0]) {
                // Check the private journal too, not just its public receipt.
                NSDictionary *journal = load(store, VDT_NICE_JOURNAL, &error);
                if (error == ENOENT) return 0;
                if (!error && [journal[@"version"] isEqual:@1] && [journal[@"boot"] isEqual:boot] &&
                    [journal[@"records"] isKindOfClass:NSDictionary.class] && [journal[@"records"] count] == 0) return 0;
            }
        }
        double now = monotonic();
        if (now < start || now - start >= 8.0) break;
        struct timespec interval = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&interval, NULL);
    }
    return ETIMEDOUT;
}
static int resourceControl(BOOL removal) {
    NSString *boot = VDTNiceBootToken(), *nonce = NSUUID.UUID.UUIDString;
    if (!boot) return ENOTSUP;
    VDTNiceStore store;
    int error = VDTNiceStoreOpen([jbroot(@"/var/tmp/com.doimty.vedette.resource") fileSystemRepresentation], removal, &store);
    if (error == ENOENT && !removal) return 0;
    if (error) return error;
    if (!removal) {
        error = VDTNiceStoreRemove(&store, VDT_NICE_REQUEST);
        VDTNiceStoreClose(&store);
        if (!error && notify_post(PREFS_CHANGED_NN.UTF8String) != NOTIFY_STATUS_OK) return EIO;
        return error;
    }
    NSData *request = [NSPropertyListSerialization dataWithPropertyList:@{@"version": @1, @"boot": boot, @"nonce": nonce}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    error = request ? VDTNiceStoreWrite(&store, VDT_NICE_REQUEST, request.bytes, request.length) : EINVAL;
    if (!error && notify_post(VDT_RESOURCE_RESTORE_NN) != NOTIFY_STATUS_OK) error = EIO;
    double start = monotonic();
    if (start < 0 && !error) error = EIO;
    for (unsigned attempt = 0; !error && attempt < 80; ++attempt) {
        NSDictionary *receipt = load(&store, VDT_NICE_STATUS, &error);
        if (!error && [receipt[@"version"] isEqual:@1] && [receipt[@"boot"] isEqual:boot] &&
            [receipt[@"restoreNonce"] isEqual:nonce] && [receipt[@"paused"] isEqual:@YES] &&
            [receipt[@"storeError"] isEqual:@0] && [receipt[@"recordCount"] isEqual:@0]) {
            NSDictionary *journal = load(&store, VDT_NICE_JOURNAL, &error);
            if (!error && [journal[@"version"] isEqual:@1] && [journal[@"boot"] isEqual:boot] &&
                [journal[@"records"] isKindOfClass:NSDictionary.class] && [journal[@"records"] count] == 0) {
                VDTNiceStoreClose(&store); return 0;
            }
        }
        // Missing initial receipts are normal while the serial queue drains.
        if (error == ENOENT) error = 0;
        if (error) break;
        double now = monotonic(); if (now < start || now - start >= 8.0) break;
        struct timespec interval = {.tv_sec=0, .tv_nsec=100000000}; nanosleep(&interval, NULL);
    }
    VDTNiceStoreClose(&store); return error ?: ETIMEDOUT;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (getuid() != 0 || geteuid() != 0) { fprintf(stderr, "nice control requires root\n"); return 1; }
        if (argc == 2 && (!strcmp(argv[1], "resource-restore-for-removal") || !strcmp(argv[1], "resource-resume"))) {
            int error = resourceControl(!strcmp(argv[1], "resource-restore-for-removal"));
            if (error) fprintf(stderr, "resource control failed (errno=%d); journal retained\n", error);
            return error ? 1 : 0;
        }
        if (argc != 2 || (strcmp(argv[1], "restore-for-removal") && strcmp(argv[1], "resume"))) {
            fprintf(stderr, "usage: vedette-nicectl restore-for-removal|resume\n"); return 2;
        }
        BOOL removal = !strcmp(argv[1], "restore-for-removal");
        VDTNiceStore store;
        int error = VDTNiceStoreOpen(VDTNiceStateDirectory().fileSystemRepresentation, removal, &store);
        if (!removal && error == ENOENT) return 0;
        if (!error) error = removal ? restore(&store) : VDTNiceStoreRemove(&store, VDT_NICE_REQUEST);
        if (!error && !removal) notify_post(VDT_NICE_RETRY_NOTIFICATION);
        VDTNiceStoreClose(&store);
        if (error) {
            fprintf(stderr, "nice restoration/control failed (errno=%d). Records retained; removal must stop.\n", error);
            return 1;
        }
        puts(removal ? "nice restoration acknowledged; no managed records remain" : "nice removal pause cleared");
        return 0;
    }
}
