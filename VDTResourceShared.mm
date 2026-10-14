// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTResourceShared.h"
#import "VDTNiceShared.h"
#import "VDTNiceStore.h"
#include <errno.h>
#include <math.h>
#include <notify.h>
#include <sys/sysctl.h>
#include <limits.h>
#include <stdlib.h>

static BOOL resourceBoolean(id value, BOOL fallback) {
    return value ? ([value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue]) : fallback;
}
NSString *VDTResourceStateDirectory(void) { return jbroot(@"/var/tmp/com.doimty.vedette.resource"); }
// The per-rule switches are the only opt-in. The former resource-write toggle
// is gone: memory/reclaim rules apply whenever they are enabled and Vedette is
// on, while a stale @"resourceWriteEnabled" key in saved preferences is
// ignored instead of blocking application.
BOOL VDTResourceWriteEnabled(NSDictionary *prefs) {
    return [prefs isKindOfClass:NSDictionary.class] && resourceBoolean(prefs[@"enabled"], YES);
}
// Only resource configuration is exposed in the readable receipt. Never copy
// CPU/nice/unknown preferences, credentials, or complete user configurations.
NSDictionary *VDTResourceConfiguration(NSDictionary *prefs) {
    if (![prefs isKindOfClass:NSDictionary.class]) prefs = @{};
    NSMutableDictionary *result = [@{@"enabled": @(resourceBoolean(prefs[@"enabled"], YES))} mutableCopy];
    for (NSString *section in @[@"memoryRules", @"jetsamRules"]) {
        id raw = prefs[section];
        if (raw && (![raw isKindOfClass:NSArray.class] || [raw count] > 4096)) {
            result[section] = @"invalid"; continue;
        }
        NSMutableArray *rows = [NSMutableArray array];
        for (id item in raw) {
            if (![item isKindOfClass:NSDictionary.class]) { [rows addObject:@"invalid"]; continue; }
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"bundleIdentifier", @"daemonName", @"extensionIdentifier", @"schema",
                @"enabled", @"active", @"inactive", @"priority", @"mode", @"band", @"sourceDarwinMajor"]) {
                id value = item[key];
                if (!value) continue;
                BOOL valid = ([value isKindOfClass:NSString.class] && [value length] <= 4096) ||
                    ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]));
                row[key] = valid ? value : @"invalid";
            }
            [rows addObject:row];
        }
        result[section] = rows;
    }
    return result;
}
static NSDictionary *resourcePrefsForUpdate(void) {
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:PREFS_PATH error:&error];
    if (!attributes) {
        // Missing prefs is the first-install case; other read/permission errors
        // must not cause replacement of an unreadable existing configuration.
        return [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError ? @{} : nil;
    }
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > VDT_NICE_STORE_LIMIT) return nil;
    id prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    return [prefs isKindOfClass:NSDictionary.class] ? prefs : nil;
}
NSDictionary *VDTResourceMatchingStatus(NSString *identifier, VDTConfigType type, NSDictionary *prefs) {
    NSString *key = VDTNiceRuleKey(type, identifier), *boot = VDTNiceBootToken();
    if (!key || !boot) return nil;
    VDTNiceStore store;
    if (VDTNiceStoreOpen(VDTResourceStateDirectory().fileSystemRepresentation, 0, &store)) return nil;
    void *bytes = NULL; size_t length = 0;
    int error = VDTNiceStoreRead(&store, VDT_NICE_STATUS, &bytes, &length);
    VDTNiceStoreClose(&store); if (error) return nil;
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
    id raw = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"version"] isEqual:@1] ||
        ![raw[@"boot"] isEqual:boot] || ![raw[@"configuration"] isEqual:VDTResourceConfiguration(prefs)]) return nil;
    NSDictionary *receipt = raw;
    if ([receipt[@"storeError"] intValue]) return @{@"state": @"store-error", @"storeError": receipt[@"storeError"]};
    if (![receipt[@"rows"] isKindOfClass:NSDictionary.class]) return nil;
    id row = receipt[@"rows"][key];
    if (![row isKindOfClass:NSDictionary.class] || ![row[@"state"] isKindOfClass:NSString.class] ||
        ![row[@"checkedAt"] isKindOfClass:NSNumber.class]) return nil;
    return row; // A historical receipt, never a claim about a live PID.
}
// Save provenance with the user-entered raw value in one atomic preference
// write. Merely turning an old rule on does not invent its missing source OS.
BOOL VDTResourceSavePriority(NSString *identifier, VDTConfigType type, NSNumber *value) {
    if (!VDTNiceRuleKey(type, identifier) || ![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite(value.doubleValue) || floor(value.doubleValue) != value.doubleValue ||
        value.doubleValue < INT32_MIN || value.doubleValue > INT32_MAX) return NO;
    char release[96] = {}; size_t length = sizeof(release);
    if (sysctlbyname("kern.osrelease", release, &length, NULL, 0) || length < 2 || length > sizeof(release) || release[length - 1]) return NO;
    errno = 0; char *end = NULL; long major = strtol(release, &end, 10);
    if (errno || major < 1 || major > INT32_MAX || !end || *end != '.') return NO;
    NSDictionary *old = resourcePrefsForUpdate();
    if (![old isKindOfClass:NSDictionary.class]) return NO;
    id raw = old[@"jetsamRules"];
    if (raw && ![raw isKindOfClass:NSArray.class]) return NO;
    NSString *idKey = type == VDTConfigTypeApp ? @"bundleIdentifier" : type == VDTConfigTypeDaemon ? @"daemonName" : @"extensionIdentifier";
    NSMutableArray *rows = [NSMutableArray array]; BOOL found = NO;
    for (id item in raw) {
        if (!found && [item isKindOfClass:NSDictionary.class] && [item[idKey] isEqual:identifier]) {
            NSMutableDictionary *row = [item mutableCopy]; row[@"sourceDarwinMajor"] = @(major); [rows addObject:row]; found = YES;
        } else [rows addObject:item];
    }
    if (!found) [rows addObject:@{idKey: identifier, @"sourceDarwinMajor": @(major)}];
    NSMutableDictionary *candidate = [old mutableCopy]; candidate[@"jetsamRules"] = rows;
    return setValueForProcessResourceRuleKeyWithPrefs(identifier, @"priority", value, type, @"jetsamRules", candidate);
}
BOOL VDTResourceFollowApp(NSString *identifier, NSString *section) {
    if (!VDTNiceRuleKey(VDTConfigTypeExtension, identifier) || ![@[@"memoryRules", @"jetsamRules"] containsObject:section]) return NO;
    NSDictionary *old = resourcePrefsForUpdate();
    if (![old isKindOfClass:NSDictionary.class] || (old[section] && ![old[section] isKindOfClass:NSArray.class])) return NO;
    NSMutableArray *rows = [NSMutableArray array];
    for (id item in old[section])
        if (!([item isKindOfClass:NSDictionary.class] && [item[@"extensionIdentifier"] isEqual:identifier])) [rows addObject:item];
    NSMutableDictionary *candidate = [old mutableCopy]; candidate[section] = rows;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:candidate format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || data.length > VDT_NICE_STORE_LIMIT || ![data writeToFile:PREFS_PATH options:NSDataWritingAtomic error:nil]) return NO;
    notify_post(PREFS_CHANGED_NN.UTF8String); return YES;
}
