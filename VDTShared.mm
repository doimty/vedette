//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTShared.h"

static NSDictionary *VDTDictionaryFromFile(NSString *path){
    id loaded = [NSDictionary dictionaryWithContentsOfFile:path];
    return [loaded isKindOfClass:[NSDictionary class]] ? loaded : @{};
}

static NSDictionary *VDTValidatedPrefs(id prefs){
    return [prefs isKindOfClass:[NSDictionary class]] ? prefs : @{};
}

static NSArray *VDTConfigArray(id value){
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSString *VDTConfigIdentifier(VDTConfigType type){
    switch (type) {
        case VDTConfigTypeApp: return @"bundleIdentifier";
        case VDTConfigTypeDaemon: return @"daemonName";
        case VDTConfigTypeExtension: return @"extensionIdentifier";
        default: return nil;
    }
}

static NSString *VDTConfigSection(VDTConfigType type){
    switch (type) {
        case VDTConfigTypeApp: return @"appConfigs";
        case VDTConfigTypeDaemon: return @"daemonConfigs";
        case VDTConfigTypeExtension: return @"extensionConfigs";
        default: return nil;
    }
}

NSDictionary* getPrefs(){
    return [VDTDictionaryFromFile(PREFS_PATH) copy];
}

NSDictionary* getTempPrefs(){
    return [VDTDictionaryFromFile(PREFS_PATH_TMP) copy];
}

id valueForKey(NSString *key){
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return nil;
    return VDTDictionaryFromFile(PREFS_PATH)[key];
}

id valueForKeyWithPrefs(NSString *key, NSDictionary *prefs){
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return nil;
    return prefs ? VDTValidatedPrefs(prefs)[key] : valueForKey(key);
}

void setValueForKeyWithPrefs(NSString *key, id value, NSDictionary *prefs){
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return;

    NSDictionary *base = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    NSMutableDictionary *newPrefs = [base mutableCopy];
    if (value) {
        newPrefs[key] = value;
    } else {
        [newPrefs removeObjectForKey:key];
    }

    [newPrefs writeToFile:PREFS_PATH atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)PREFS_CHANGED_NN,
                                         NULL,
                                         NULL,
                                         YES);
}

void setValueForKey(NSString *key, id value){
    setValueForKeyWithPrefs(key, value, nil);
}

id valueForProcessConfigKeyWithPrefs(NSString *identifier,
                                     NSString *key,
                                     id defaultValue,
                                     VDTConfigType type,
                                     NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
        ![key isKindOfClass:[NSString class]] || key.length == 0) {
        return defaultValue;
    }

    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    NSString *identifierKey = VDTConfigIdentifier(type);
    NSString *sectionKey = VDTConfigSection(type);
    if (!identifierKey || !sectionKey) return defaultValue;
    BOOL cpuField = [@[@"enabled", @"percentage", @"interval", @"violationPolicy"] containsObject:key];
    BOOL niceField = [@[@"niceEnabled", @"niceValue", @"niceRevision"] containsObject:key];
    for (id rawConfig in VDTConfigArray(source[sectionKey])) {
        if (![rawConfig isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *config = rawConfig;
        // First record with this family's intent wins, including disabled or
        // malformed intent. A row containing only the other family must not
        // hide a later independent rule for the same extension identifier.
        if (type == VDTConfigTypeExtension &&
            ((cpuField && !VDTProcessConfigHasCPUFields(config)) ||
             (niceField && !config[@"niceEnabled"] && !config[@"niceValue"] && !config[@"niceRevision"]))) continue;
        id configuredIdentifier = config[identifierKey];
        if ([configuredIdentifier isKindOfClass:[NSString class]] &&
            [configuredIdentifier isEqualToString:identifier]) {
            return config[key] ?: defaultValue;
        }
    }
    return defaultValue;
}

id valueForProcessConfigKey(NSString *identifier, NSString *key, id defaultValue, VDTConfigType type){
    return valueForProcessConfigKeyWithPrefs(identifier, key, defaultValue, type, nil);
}

void setValueForProcessConfigKeyWithPrefs(NSString *identifier,
                                          NSString *key,
                                          id value,
                                          VDTConfigType type,
                                          NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
        ![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }

    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    NSString *sectionKey = VDTConfigSection(type);
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!identifierKey || !sectionKey) return;
    NSMutableArray *configs = [VDTConfigArray(source[sectionKey]) mutableCopy];
    NSUInteger matchedIndex = NSNotFound, firstMatch = NSNotFound;
    BOOL cpuField = [@[@"enabled", @"percentage", @"interval", @"violationPolicy"] containsObject:key];

    for (NSUInteger index = 0; index < configs.count; index++) {
        id rawConfig = configs[index];
        if (![rawConfig isKindOfClass:[NSDictionary class]]) continue;
        id configuredIdentifier = ((NSDictionary *)rawConfig)[identifierKey];
        if ([configuredIdentifier isKindOfClass:[NSString class]] &&
            [configuredIdentifier isEqualToString:identifier]) {
            if (firstMatch == NSNotFound) firstMatch = index;
            if (type == VDTConfigTypeExtension && cpuField && !VDTProcessConfigHasCPUFields(rawConfig)) continue;
            matchedIndex = index;
            break;
        }
    }
    if (matchedIndex == NSNotFound) matchedIndex = firstMatch;

    if (matchedIndex != NSNotFound) {
        NSMutableDictionary *config = [configs[matchedIndex] mutableCopy];
        if (value) {
            config[key] = value;
        } else {
            [config removeObjectForKey:key];
        }
        configs[matchedIndex] = config;
    } else if (value) {
        [configs addObject:@{identifierKey: identifier, key: value}];
    }

    setValueForKeyWithPrefs(sectionKey, configs, source);
}

void setValueForProcessConfigKey(NSString *identifier, NSString *key, id value, VDTConfigType type){
    setValueForProcessConfigKeyWithPrefs(identifier, key, value, type, nil);
}

BOOL VDTProcessConfigHasCPUFields(NSDictionary *entry){
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    for (NSString *key in @[@"enabled", @"percentage", @"interval", @"violationPolicy"])
        if (entry[key]) return YES;
    return NO;
}

BOOL VDTHasProcessConfig(NSString *identifier, VDTConfigType type, NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return NO;
    NSString *sectionKey = VDTConfigSection(type);
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!sectionKey || !identifierKey) return NO;
    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    for (id raw in VDTConfigArray(source[sectionKey])) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        id value = ((NSDictionary *)raw)[identifierKey];
        if ([value isKindOfClass:[NSString class]] && [value isEqualToString:identifier] &&
            (type != VDTConfigTypeExtension || VDTProcessConfigHasCPUFields(raw))) return YES;
    }
    return NO;
}

void VDTRemoveProcessConfig(NSString *identifier, VDTConfigType type){
    if (type == VDTConfigTypeExtension) {
        (void)VDTRemoveExtensionCPUConfigReportingResult(identifier);
        return;
    }
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return;
    NSString *sectionKey = VDTConfigSection(type);
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!sectionKey || !identifierKey) return;
    NSDictionary *source = VDTDictionaryFromFile(PREFS_PATH);
    NSMutableArray *remaining = [NSMutableArray new];
    BOOL removed = NO;
    for (id raw in VDTConfigArray(source[sectionKey])) {
        id value = [raw isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)raw)[identifierKey] : nil;
        if ([value isKindOfClass:[NSString class]] && [value isEqualToString:identifier]) {
            removed = YES;
        } else {
            [remaining addObject:raw];
        }
    }
    if (removed) setValueForKeyWithPrefs(sectionKey, remaining, source);
}

// Independent per-resource rule storage (memoryRules / jetsamRules). These
// sections mirror the CPU configuration layout but never share a record with
// it, and every record carries a schema marker for forward compatibility.
#define VDT_RESOURCE_RULE_SCHEMA_VERSION @1

static BOOL VDTSavePrefsReportingResult(NSDictionary *candidate){
    if (![candidate isKindOfClass:[NSDictionary class]]) return NO;
    BOOL saved = [candidate writeToFile:PREFS_PATH atomically:YES];
    if (!saved) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)PREFS_CHANGED_NN,
                                         NULL,
                                         NULL,
                                         YES);
    return YES;
}

BOOL VDTRemoveExtensionCPUConfigReportingResult(NSString *identifier){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return NO;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:PREFS_PATH error:nil];
    if (!attributes) return ![[NSFileManager defaultManager] fileExistsAtPath:PREFS_PATH];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return NO;
    id loaded = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (![loaded isKindOfClass:[NSDictionary class]]) return NO;
    id rawSection = loaded[@"extensionConfigs"];
    if (rawSection && ![rawSection isKindOfClass:[NSArray class]]) return NO;
    NSMutableArray *remaining = [NSMutableArray new];
    BOOL removed = NO;
    for (id raw in rawSection) {
        if ([raw isKindOfClass:[NSDictionary class]] && [raw[@"extensionIdentifier"] isEqual:identifier]) {
            NSMutableDictionary *entry = [raw mutableCopy];
            removed = removed || VDTProcessConfigHasCPUFields(entry);
            for (NSString *key in @[@"enabled", @"percentage", @"interval", @"violationPolicy"])
                [entry removeObjectForKey:key];
            if (entry.count > 1) [remaining addObject:entry];
        } else [remaining addObject:raw];
    }
    if (!removed) return YES;
    NSMutableDictionary *prefs = [loaded mutableCopy];
    prefs[@"extensionConfigs"] = remaining;
    return VDTSavePrefsReportingResult(prefs);
}

id valueForProcessResourceRuleKeyWithPrefs(NSString *identifier,
                                           NSString *key,
                                           id defaultValue,
                                           VDTConfigType type,
                                           NSString *sectionKey,
                                           NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
        ![key isKindOfClass:[NSString class]] || key.length == 0 ||
        ![sectionKey isKindOfClass:[NSString class]] || sectionKey.length == 0) {
        return defaultValue;
    }
    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!identifierKey) return defaultValue;
    for (id rawConfig in VDTConfigArray(source[sectionKey])) {
        if (![rawConfig isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *config = rawConfig;
        id configuredIdentifier = config[identifierKey];
        if ([configuredIdentifier isKindOfClass:[NSString class]] &&
            [configuredIdentifier isEqualToString:identifier]) {
            return config[key] ?: defaultValue;
        }
    }
    return defaultValue;
}

id valueForProcessResourceRuleKey(NSString *identifier, NSString *key, id defaultValue, VDTConfigType type, NSString *sectionKey){
    return valueForProcessResourceRuleKeyWithPrefs(identifier, key, defaultValue, type, sectionKey, nil);
}

BOOL setValueForProcessResourceRuleKeyWithPrefs(NSString *identifier,
                                                NSString *key,
                                                id value,
                                                VDTConfigType type,
                                                NSString *sectionKey,
                                                NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
        ![key isKindOfClass:[NSString class]] || key.length == 0 ||
        ![sectionKey isKindOfClass:[NSString class]] || sectionKey.length == 0) {
        return NO;
    }
    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!identifierKey) return NO;
    NSMutableArray *configs = [VDTConfigArray(source[sectionKey]) mutableCopy];
    NSUInteger matchedIndex = NSNotFound;
    for (NSUInteger index = 0; index < configs.count; index++) {
        id rawConfig = configs[index];
        if (![rawConfig isKindOfClass:[NSDictionary class]]) continue;
        id configuredIdentifier = ((NSDictionary *)rawConfig)[identifierKey];
        if ([configuredIdentifier isKindOfClass:[NSString class]] &&
            [configuredIdentifier isEqualToString:identifier]) {
            matchedIndex = index;
            break;
        }
    }
    BOOL changed = NO;
    if (matchedIndex != NSNotFound) {
        NSMutableDictionary *config = [configs[matchedIndex] mutableCopy];
        config[@"schema"] = VDT_RESOURCE_RULE_SCHEMA_VERSION;
        if (value) {
            config[key] = value;
        } else {
            [config removeObjectForKey:key];
        }
        configs[matchedIndex] = config;
        changed = YES;
    } else if (value) {
        [configs addObject:@{identifierKey: identifier, @"schema": VDT_RESOURCE_RULE_SCHEMA_VERSION, key: value}];
        changed = YES;
    }
    if (!changed) return YES;
    NSMutableDictionary *newPrefs = [source mutableCopy];
    newPrefs[sectionKey] = configs;
    return VDTSavePrefsReportingResult(newPrefs);
}

BOOL setValueForProcessResourceRuleKey(NSString *identifier, NSString *key, id value, VDTConfigType type, NSString *sectionKey){
    return setValueForProcessResourceRuleKeyWithPrefs(identifier, key, value, type, sectionKey, nil);
}

BOOL VDTHasProcessResourceRule(NSString *identifier, VDTConfigType type, NSString *sectionKey, NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
        ![sectionKey isKindOfClass:[NSString class]] || sectionKey.length == 0) return NO;
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!identifierKey) return NO;
    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    for (id raw in VDTConfigArray(source[sectionKey])) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        id value = ((NSDictionary *)raw)[identifierKey];
        if ([value isKindOfClass:[NSString class]] && [value isEqualToString:identifier]) return YES;
    }
    return NO;
}

void VDTRemoveProcessResourceRule(NSString *identifier, VDTConfigType type, NSString *sectionKey){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
        ![sectionKey isKindOfClass:[NSString class]] || sectionKey.length == 0) return;
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!identifierKey) return;
    NSDictionary *source = VDTDictionaryFromFile(PREFS_PATH);
    NSMutableArray *remaining = [NSMutableArray new];
    BOOL removed = NO;
    for (id raw in VDTConfigArray(source[sectionKey])) {
        id value = [raw isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)raw)[identifierKey] : nil;
        if ([value isKindOfClass:[NSString class]] && [value isEqualToString:identifier]) {
            removed = YES;
        } else {
            [remaining addObject:raw];
        }
    }
    if (removed) {
        NSMutableDictionary *newPrefs = [source mutableCopy];
        newPrefs[sectionKey] = remaining;
        VDTSavePrefsReportingResult(newPrefs);
    }
}
