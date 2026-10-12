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

BOOL VDTHasProcessConfig(NSString *identifier, VDTConfigType type, NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return NO;
    NSString *sectionKey = VDTConfigSection(type);
    NSString *identifierKey = VDTConfigIdentifier(type);
    if (!sectionKey || !identifierKey) return NO;
    NSDictionary *source = prefs ? VDTValidatedPrefs(prefs) : VDTDictionaryFromFile(PREFS_PATH);
    for (id raw in VDTConfigArray(source[sectionKey])) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        id value = ((NSDictionary *)raw)[identifierKey];
        if ([value isKindOfClass:[NSString class]] && [value isEqualToString:identifier]) return YES;
    }
    return NO;
}

void VDTRemoveProcessConfig(NSString *identifier, VDTConfigType type){
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
