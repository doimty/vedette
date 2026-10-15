// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultReader.h"
#import "../VDTNiceShared.h"
#import "../VDTResourceShared.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>

static NSDictionary *resourceRule(NSString *section, NSString *identifier, VDTConfigType type,
    NSString *host, NSDictionary *prefs) {
    // Presence-first inheritance: even an invalid/off own row blocks its host.
    NSString *source = identifier; VDTConfigType sourceType = type;
    if (!VDTHasProcessResourceRule(source, sourceType, section, prefs)) {
        if (type != VDTConfigTypeExtension || !host || !VDTHasProcessResourceRule(host, VDTConfigTypeApp, section, prefs)) return nil;
        source = host; sourceType = VDTConfigTypeApp;
    }
    NSMutableDictionary *rule = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"enabled", @"schema", @"active", @"inactive", @"priority", @"sourceDarwinMajor"]) {
        id value = valueForProcessResourceRuleKeyWithPrefs(source, key, nil, sourceType, section, prefs);
        if (value) rule[key] = value;
    }
    return rule;
}
NSArray<NSDictionary *> *VDTReadCheckResultModels(NSDictionary *context, BOOL nicePending,
    VDTCheckLocalizer localize) {
    if (![context isKindOfClass:NSDictionary.class]) return VDTCheckResultModels(nil, nil, nil, nil, nil, localize);
    id value = context[@"type"];
    const char *encoding = [value isKindOfClass:NSNumber.class] ? [value objCType] : NULL;
    if (!encoding || strlen(encoding) != 1 || !strchr("cCsSiIlLqQ", encoding[0]) ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        [value longLongValue] < VDTConfigTypeApp || [value unsignedLongLongValue] > VDTConfigTypeExtension)
        return VDTCheckResultModels(nil, nil, nil, nil, nil, localize);
    VDTConfigType type = (VDTConfigType)[value unsignedIntegerValue];
    NSString *identifier = context[@"identifier"];
    if (!VDTNiceRuleKey(type, identifier)) return VDTCheckResultModels(nil, nil, nil, nil, nil, localize);
    NSString *host = type == VDTConfigTypeExtension && VDTNiceRuleKey(VDTConfigTypeApp, context[@"host"])
        ? context[@"host"] : nil;
    // One saved configuration snapshot for all three mechanisms. Never apply,
    // reconcile, resume, or generate a new observation on a display refresh.
    NSDictionary *prefs = getPrefs();
    if (![prefs isKindOfClass:NSDictionary.class]) prefs = @{};
    NSDictionary *niceRule = VDTNiceEffectiveRule(identifier, type, host, prefs);
    NSDictionary *niceReceipt = nicePending ? nil : VDTNiceMatchingStatusWithHost(identifier, type, host, prefs);
    NSDictionary *resourceReceipt = VDTResourceMatchingStatus(identifier, type, prefs);
    return VDTCheckResultModels(niceRule, niceReceipt,
        resourceRule(@"memoryRules", identifier, type, host, prefs),
        resourceRule(@"jetsamRules", identifier, type, host, prefs), resourceReceipt, localize);
}
