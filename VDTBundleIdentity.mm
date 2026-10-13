// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import "VDTBundleIdentity.h"
#include "VDTBundleRules.h"
#include <limits.h>

NSString *VDTNearestBundlePath(NSString *executablePath, NSString *suffix) {
    if (![executablePath isKindOfClass:[NSString class]] ||
        ![suffix isKindOfClass:[NSString class]]) return nil;
    char path[PATH_MAX];
    if (!VDTCopyNearestBundlePath(executablePath.UTF8String, suffix.UTF8String,
                                 path, sizeof(path))) return nil;
    return [NSString stringWithUTF8String:path];
}

static NSString *valid_string(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

NSDictionary<NSString *, NSString *> *VDTReadExtensionBundleInfo(NSString *bundlePath,
                                                               NSString *executablePath) {
    if (![bundlePath isKindOfClass:[NSString class]] || bundlePath.length == 0 ||
        ![bundlePath hasPrefix:@"/"] ||
        [bundlePath.pathExtension caseInsensitiveCompare:@"appex"] != NSOrderedSame) return nil;
    id raw = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *info = raw;
    NSString *identifier = valid_string(info[@"CFBundleIdentifier"]);
    NSString *name = valid_string(info[@"CFBundleExecutable"]);
    id extension = info[@"NSExtension"];
    if (!identifier || !VDTBundleExecutableNameIsValid(name.UTF8String) ||
        ![extension isKindOfClass:[NSDictionary class]] ||
        !valid_string(((NSDictionary *)extension)[@"NSExtensionPointIdentifier"])) return nil;
    NSString *expectedPath = [bundlePath stringByAppendingPathComponent:name];
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:expectedPath isDirectory:&isDirectory] || isDirectory) return nil;
    if (executablePath && (![executablePath isKindOfClass:[NSString class]] ||
        ![expectedPath isEqualToString:executablePath])) return nil;
    NSString *displayName = valid_string(info[@"CFBundleDisplayName"]) ?: valid_string(info[@"CFBundleName"]) ?: identifier;
    NSMutableDictionary *result = [@{@"extensionIdentifier": identifier,
        @"displayName": displayName, @"bundlePath": bundlePath,
        @"executablePath": expectedPath} mutableCopy];
    NSString *container = VDTNearestBundlePath(bundlePath, @"app");
    if (container) result[@"containingAppPath"] = container;
    return [result copy];
}
