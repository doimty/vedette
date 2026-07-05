//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTShared.h"

static NSDictionary* safeDictionaryFromFile(NSString *path){
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : @{};
}

static NSMutableArray* mutableConfigArrayForType(VDTConfigType type, NSDictionary *prefs){
    id configs = nil;
    if (!prefs){
        configs = valueForKey(type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs");
    }else{
        configs = prefs[type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs"];
    }
    return [configs isKindOfClass:[NSArray class]] ? [configs mutableCopy] : [NSMutableArray array];
}

NSDictionary* getPrefs(){
    return [safeDictionaryFromFile(PREFS_PATH) copy];
}

NSDictionary* getTempPrefs(){
    return [safeDictionaryFromFile(PREFS_PATH_TMP) copy];
}

id valueForKey(NSString *key){
    NSDictionary *prefs = safeDictionaryFromFile(PREFS_PATH);
    return prefs[key] ?: nil;
}

id valueForKeyWithPrefs(NSString *key, NSDictionary *prefs){
    if (!prefs){
        return (valueForKey(key));
    }
    return prefs[key] ?: nil;
}

void setValueForKeyWithPrefs(NSString *key, id value, NSDictionary *prefs){
    NSMutableDictionary *newPrefs = prefs ? [prefs mutableCopy] : [safeDictionaryFromFile(PREFS_PATH) mutableCopy];
    if (!newPrefs){
        newPrefs = [NSMutableDictionary dictionary];
    }
    if (key && value){
        [newPrefs setObject:value forKey:key];
    }
    [newPrefs writeToFile:PREFS_PATH atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (CFStringRef)PREFS_CHANGED_NN, NULL, NULL, YES);
}

void setValueForKey(NSString *key, id value){
    setValueForKeyWithPrefs(key, value, nil);
}

id valueForProcessConfigKeyWithPrefs(NSString *identifier, NSString *key, id defaultValue, VDTConfigType type, NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0){
        return defaultValue;
    }
    id configs;
    if (!prefs){
        configs = valueForKey(type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs");
    }else{
        configs = prefs[type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs"];
    }
    if ([configs isKindOfClass:[NSArray class]]){
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K == %@", (type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName"), identifier];
        NSDictionary *config = [configs filteredArrayUsingPredicate:predicate].firstObject;
        return config[key] ?: defaultValue;
    }
    return defaultValue;
}

id valueForProcessConfigKey(NSString *identifier, NSString *key, id defaultValue, VDTConfigType type){
    return valueForProcessConfigKeyWithPrefs(identifier, key, defaultValue, type, nil);
}

void setValueForProcessConfigKeyWithPrefs(NSString *identifier, NSString *key, id value, VDTConfigType type, NSDictionary *prefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 || !key || !value){
        return;
    }

    NSMutableArray *configs = mutableConfigArrayForType(type, prefs);
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K == %@", (type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName"), identifier];
    NSMutableDictionary *config = [[configs filteredArrayUsingPredicate:predicate].firstObject mutableCopy];
    if (config){
        NSUInteger idx = [configs indexOfObject:config];
        config[key] = value;
        if (idx != NSNotFound){
            [configs replaceObjectAtIndex:idx withObject:config];
        }else{
            [configs addObject:config];
        }
    }else{
        [configs addObject:@{
            (type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName"):identifier,
            key:value
        }];
    }
    setValueForKeyWithPrefs((type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs"), configs, prefs);
}

void setValueForProcessConfigKey(NSString *identifier, NSString *key, id value, VDTConfigType type){
    setValueForProcessConfigKeyWithPrefs(identifier, key, value, type, nil);
}
