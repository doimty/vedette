// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTNiceShared.h"
#import "VDTNiceStore.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <notify.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static BOOL niceBoolean(id value, BOOL missingDefault) {
    return value ? ([value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue]) : missingDefault;
}
BOOL VDTNiceParseValue(id value, int *result) {
    if (!result) return NO;
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
        double n = [value doubleValue];
        if (!isfinite(n) || n < VDTNiceMinimum || n > VDTNiceMaximum || floor(n) != n) return NO;
        *result = (int)n; return YES;
    }
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 32) return NO;
    const char *text = [value UTF8String];
    if (!text) return NO;
    const char *p = text;
    if (*p == '-' || *p == '+') ++p;
    if (!*p) return NO;
    for (; *p; ++p) if (*p < '0' || *p > '9') return NO;
    // Embedded NUL must not turn an invalid string into a valid prefix.
    if (strlen(text) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return NO;
    errno = 0; char *end = NULL; long n = strtol(text, &end, 10);
    if (errno || !end || *end || n < VDTNiceMinimum || n > VDTNiceMaximum) return NO;
    *result = (int)n; return YES;
}
NSString *VDTNiceRuleKey(VDTConfigType type, NSString *identifier) {
    if ((type != VDTConfigTypeApp && type != VDTConfigTypeDaemon) ||
        ![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length > 1024) return nil;
    return [NSString stringWithFormat:@"%lu:%@", (unsigned long)type, identifier];
}
NSString *VDTNiceStateDirectory(void) { return jbroot(@"/var/tmp/com.doimty.vedette.nice"); }
NSString *VDTNiceBootToken(void) {
    struct timeval boot = {}; size_t length = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &length, NULL, 0) || length != sizeof(boot) ||
        boot.tv_sec <= 0 || boot.tv_usec < 0 || boot.tv_usec >= 1000000) return nil;
    return [NSString stringWithFormat:@"%lld:%ld", (long long)boot.tv_sec, (long)boot.tv_usec];
}
NSDictionary<NSString *, NSDictionary *> *VDTNiceRulesFromPrefs(NSDictionary *prefs) {
    if (![prefs isKindOfClass:NSDictionary.class]) return @{};
    BOOL global = niceBoolean(prefs[@"enabled"], YES);
    NSMutableDictionary *rules = [NSMutableDictionary dictionary];
    for (NSUInteger type = VDTConfigTypeApp; type <= VDTConfigTypeDaemon; ++type) {
        NSString *section = type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs";
        NSString *identifierKey = type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName";
        id raw = prefs[section];
        if (![raw isKindOfClass:NSArray.class]) continue;
        for (id item in (NSArray *)raw) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *entry = item; NSString *identifier = entry[identifierKey];
            NSString *key = VDTNiceRuleKey((VDTConfigType)type, identifier);
            if (!key || rules[key]) continue; // Includes disabled first entries.
            id flag = entry[VDT_NICE_ENABLED_KEY];
            BOOL requested = niceBoolean(flag, NO);
            BOOL valid = !flag || ([flag isKindOfClass:NSNumber.class] &&
                CFGetTypeID((__bridge CFTypeRef)flag) == CFBooleanGetTypeID());
            int value = 0;
            BOOL valueValid = VDTNiceParseValue(entry[VDT_NICE_VALUE_KEY], &value);
            if (entry[VDT_NICE_VALUE_KEY] || requested) valid = valid && valueValid;
            id revision = entry[VDT_NICE_REVISION_KEY];
            if (revision && (![revision isKindOfClass:NSString.class] || [revision length] > 80)) {
                valid = NO; revision = nil;
            }
            rules[key] = @{@"identifier": identifier, @"type": @(type), @"value": @(value),
                @"requestedEnabled": @(requested), @"enabled": @(global && requested && valid),
                @"valid": @(valid), @"revision": revision ?: @""};
        }
    }
    return [rules copy];
}

static BOOL preferenceError(NSError **error, int code, NSString *text) {
    if (error) *error = [NSError errorWithDomain:@"com.doimty.vedette.nice-preferences" code:code
        userInfo:@{NSLocalizedDescriptionKey: text}];
    return NO;
}
static NSDictionary *readWritablePrefs(NSError **error) {
    int fd = open(PREFS_PATH.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) return @{};
        preferenceError(error, errno, @"Cannot read the existing preferences."); return nil;
    }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > VDT_NICE_STORE_LIMIT) {
        close(fd); preferenceError(error, EINVAL, @"Existing preferences are not a bounded regular file."); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t used = 0; int failure = 0;
    while (used < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + used, data.length - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { failure = n < 0 ? errno : EIO; break; }
        used += (size_t)n;
    }
    close(fd);
    if (failure) { preferenceError(error, failure, @"Cannot read all existing preferences."); return nil; }
    id result = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    if (![result isKindOfClass:NSDictionary.class]) {
        preferenceError(error, EINVAL, @"Existing preferences are invalid; they were not replaced."); return nil;
    }
    return result;
}
BOOL VDTNiceSavePreference(NSString *identifier, VDTConfigType type, NSString *key, id value, NSError **error) {
    if (!VDTNiceRuleKey(type, identifier) || ![key isKindOfClass:NSString.class])
        return preferenceError(error, EINVAL, @"Invalid target or preference key.");
    BOOL isSwitch = [key isEqualToString:VDT_NICE_ENABLED_KEY];
    int numeric = 0;
    if (isSwitch) {
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
            return preferenceError(error, EINVAL, @"Invalid nice switch.");
    } else if (![key isEqualToString:VDT_NICE_VALUE_KEY] || !VDTNiceParseValue(value, &numeric)) {
        return preferenceError(error, EINVAL, @"Nice must be an integer from -20 to 20.");
    }
    NSDictionary *old = readWritablePrefs(error);
    if (!old) return NO;
    NSMutableDictionary *prefs = [old mutableCopy];
    NSString *sectionKey = type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs";
    NSString *idKey = type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName";
    id rawSection = prefs[sectionKey];
    if (rawSection && ![rawSection isKindOfClass:NSArray.class])
        return preferenceError(error, EINVAL, @"Invalid existing rule list; it was not replaced.");
    NSMutableArray *section = rawSection ? [rawSection mutableCopy] : [NSMutableArray array];
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < section.count; ++i) {
        id entry = section[i];
        if ([entry isKindOfClass:NSDictionary.class] && [entry[idKey] isKindOfClass:NSString.class] &&
            [entry[idKey] isEqualToString:identifier]) { index = i; break; }
    }
    NSMutableDictionary *entry = index == NSNotFound ? [@{idKey: identifier} mutableCopy] : [section[index] mutableCopy];
    entry[key] = isSwitch ? value : @(numeric);
    if (isSwitch && [value boolValue] && !entry[VDT_NICE_VALUE_KEY]) entry[VDT_NICE_VALUE_KEY] = @0;
    entry[VDT_NICE_REVISION_KEY] = NSUUID.UUID.UUIDString;
    if (index == NSNotFound) [section addObject:entry]; else section[index] = entry;
    prefs[sectionKey] = section;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || data.length > VDT_NICE_STORE_LIMIT) return preferenceError(error, EFBIG, @"Preferences exceed the safe size limit.");
    if (![data writeToFile:PREFS_PATH options:NSDataWritingAtomic error:error]) return NO;
    notify_post([PREFS_CHANGED_NN UTF8String]);
    return YES;
}
NSDictionary *VDTNiceMatchingStatus(NSString *identifier, VDTConfigType type, NSDictionary *prefs) {
    NSString *key = VDTNiceRuleKey(type, identifier);
    NSDictionary *rule = key ? VDTNiceRulesFromPrefs(prefs)[key] : nil;
    if (key && !rule) rule = @{@"identifier": identifier, @"type": @(type), @"value": @0,
        @"valid": @YES, @"enabled": @NO, @"requestedEnabled": @NO, @"revision": @""};
    NSString *boot = VDTNiceBootToken();
    if (!rule || !boot) return nil;
    VDTNiceStore store;
    if (VDTNiceStoreOpen(VDTNiceStateDirectory().fileSystemRepresentation, 0, &store)) return nil;
    void *bytes = NULL; size_t length = 0;
    int error = VDTNiceStoreRead(&store, VDT_NICE_STATUS, &bytes, &length);
    VDTNiceStoreClose(&store);
    if (error) return nil;
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
    id raw = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *receipt = raw;
    if (![receipt[@"version"] isEqual:@1] || ![receipt[@"boot"] isEqual:boot] ||
        ![receipt[@"rules"] isKindOfClass:NSDictionary.class]) return nil;
    id row = receipt[@"rules"][key];
    if (![row isKindOfClass:NSDictionary.class] || ![row[@"state"] isKindOfClass:NSString.class]) return nil;
    for (NSString *field in @[@"value", @"valid", @"revision", @"enabled", @"requestedEnabled"])
        if (![row[field] isEqual:rule[field]]) return nil;
    return row;
}
