// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultReader.h"
#import "../VDTNiceShared.h"
#import "../VDTResourceShared.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>

static BOOL readerBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL readerGlobalValid(NSDictionary *prefs) {
    return [prefs isKindOfClass:NSDictionary.class] && (!prefs[@"enabled"] || readerBoolean(prefs[@"enabled"]));
}
static BOOL readerSectionValid(NSDictionary *prefs, NSString *section) {
    if (![prefs isKindOfClass:NSDictionary.class]) return NO;
    id raw = prefs[section];
    if (!raw) return YES; // A readable snapshot can establish absence, not an IO failure.
    if (![raw isKindOfClass:NSArray.class] || [raw count] > 4096) return NO;
    for (id item in raw) if (![item isKindOfClass:NSDictionary.class]) return NO;
    return YES;
}
static NSDictionary *readerRule(NSDictionary *rule, NSDictionary *prefs, BOOL sectionValid) {
    NSMutableDictionary *result = [rule mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL available = [prefs isKindOfClass:NSDictionary.class];
    result[@"settingsAvailable"] = @(available);
    result[@"configurationValid"] = available && readerGlobalValid(prefs) && sectionValid ? @YES : @NO;
    if (readerGlobalValid(prefs)) result[@"globallyEnabled"] = prefs[@"enabled"] ?: @YES;
    return [result copy];
}
static NSDictionary *resourceRule(NSString *section, NSString *identifier, VDTConfigType type,
    NSString *host, NSDictionary *prefs) {
    // Never pass nil to legacy WithPrefs getters: nil would reread/default the
    // file and cease to be this display's strict, single saved snapshot.
    if (![prefs isKindOfClass:NSDictionary.class] || !readerSectionValid(prefs, section))
        return readerRule(nil, prefs, NO);
    // Presence-first inheritance: even an invalid/off own row blocks its host.
    NSString *source = identifier; VDTConfigType sourceType = type;
    if (!VDTHasProcessResourceRule(source, sourceType, section, prefs)) {
        if (type != VDTConfigTypeExtension || !host || !VDTHasProcessResourceRule(host, VDTConfigTypeApp, section, prefs))
            return readerRule(@{@"present": @NO, @"enabled": @NO}, prefs, YES);
        source = host; sourceType = VDTConfigTypeApp;
    }
    NSMutableDictionary *rule = [NSMutableDictionary dictionaryWithDictionary:@{@"present": @YES}];
    for (NSString *key in @[@"enabled", @"schema", @"active", @"inactive", @"priority", @"sourceDarwinMajor"]) {
        id value = valueForProcessResourceRuleKeyWithPrefs(source, key, nil, sourceType, section, prefs);
        if (value) rule[key] = value;
    }
    return readerRule(rule, prefs, YES);
}
static NSDictionary *readerReceipt(NSDictionary *receipt, NSDictionary *prefs) {
    BOOL available = [prefs isKindOfClass:NSDictionary.class];
    if (!receipt && available) return nil;
    NSMutableDictionary *result = [receipt mutableCopy] ?: [NSMutableDictionary dictionary];
    result[@"settingsAvailable"] = @(available);
    if (!readerGlobalValid(prefs)) result[@"configurationValid"] = @NO;
    return [result copy];
}
NSArray<NSDictionary *> *VDTReadCheckResultModels(NSDictionary *context, BOOL nicePending,
    VDTCheckLocalizer localize) {
    if (![context isKindOfClass:NSDictionary.class]) return VDTCheckResultModels(nil, nil, nil, nil, nil, localize);
    id value = context[@"type"];
    const char *encoding = [value isKindOfClass:NSNumber.class] ? [value objCType] : NULL;
    if (!encoding || strlen(encoding) != 1 || !strchr("cCsSiIlLqQ", encoding[0]) ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        [value longLongValue] < (long long)VDTConfigTypeApp || [value unsignedLongLongValue] > (unsigned long long)VDTConfigTypeExtension)
        return VDTCheckResultModels(nil, nil, nil, nil, nil, localize);
    VDTConfigType type = (VDTConfigType)[value unsignedIntegerValue];
    NSString *identifier = context[@"identifier"];
    if (!VDTNiceRuleKey(type, identifier)) return VDTCheckResultModels(nil, nil, nil, nil, nil, localize);
    NSString *host = type == VDTConfigTypeExtension && VDTNiceRuleKey(VDTConfigTypeApp, context[@"host"])
        ? context[@"host"] : nil;
    // All three mechanisms use ONE strict immutable saved snapshot. Missing,
    // unreadable, corrupt, nonregular or oversized settings stay unavailable;
    // no empty-dictionary default may invent disabled rules or successful checks.
    NSDictionary *prefs = VDTResourceReadPreferences();
    NSDictionary *niceRule = nil, *niceReceipt = nil;
    if ([prefs isKindOfClass:NSDictionary.class]) {
        NSString *section = type == VDTConfigTypeApp ? @"appConfigs" : type == VDTConfigTypeDaemon ? @"daemonConfigs" : @"extensionConfigs";
        BOOL sectionValid = readerSectionValid(prefs, section) &&
            (type != VDTConfigTypeExtension || !host || readerSectionValid(prefs, @"appConfigs"));
        niceRule = readerRule(VDTNiceEffectiveRule(identifier, type, host, prefs), prefs, sectionValid);
        niceReceipt = VDTNiceMatchingStatusWithHost(identifier, type, host, prefs);
    } else niceRule = readerRule(nil, prefs, NO);
    niceReceipt = readerReceipt(niceReceipt, prefs);
    if (nicePending) {
        // This is a transient local presentation flag, not a new observation.
        // Keep the real old readback and check time instead of suppressing them.
        NSMutableDictionary *pending = [niceReceipt mutableCopy] ?: [NSMutableDictionary dictionary];
        pending[@"localPending"] = @YES;
        niceReceipt = [pending copy];
    }
    NSDictionary *resourceReceipt = readerReceipt(VDTResourceMatchingStatus(identifier, type, prefs), prefs);
    // No apply/reconcile, retry, notification, timer, SET or current-time fallback.
    return VDTCheckResultModels(niceRule, niceReceipt,
        resourceRule(@"memoryRules", identifier, type, host, prefs),
        resourceRule(@"jetsamRules", identifier, type, host, prefs), resourceReceipt, localize);
}
