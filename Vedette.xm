//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"

#include <notify.h>

#pragma mark processes
static void notify_new_pid(const char *notificationName, uint64_t pid){
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int token = 0;
        notify_register_check(notificationName, &token);
        notify_set_state(token, pid);
        notify_cancel(token);
        notify_post(notificationName);
    });
}

static void notify_rescan(const char *notificationName){
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        notify_post(notificationName);
    });
}

#pragma mark runningboardd
static int notify_pid_token;

static void reloadPrefs(void);
static void restoreAllMonitors(void);
static dispatch_queue_t VedetteApplyQueue(void);

static dispatch_queue_t VedetteApplyQueue(void){
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.udevs.vedette.apply", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void VedettePrefsChangedCallback(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    reloadPrefs();
}

static void VedetteRestoreAllMonitorsCallback(CFNotificationCenterRef center,
                                              void *observer,
                                              CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
    restoreAllMonitors();
}

static NSArray* safeConfigArray(NSDictionary *source, NSString *key){
    id configs = source[key];
    return [configs isKindOfClass:[NSArray class]] ? configs : @[];
}

static int positiveIntValue(id value, int defaultValue){
    if (!value || ![value respondsToSelector:@selector(intValue)]){
        return defaultValue;
    }
    int ret = [value intValue];
    return ret > 0 ? ret : defaultValue;
}

static VDTViolationPolicy validViolationPolicy(id value, VDTViolationPolicy defaultValue){
    if (!value || ![value respondsToSelector:@selector(unsignedLongValue)]){
        return defaultValue;
    }
    VDTViolationPolicy policy = (VDTViolationPolicy)[value unsignedLongValue];
    switch (policy) {
        case VDTViolationPolicyMonitorAndTerminate:
        case VDTViolationPolicyMonitor:
        case VDTViolationPolicyThrottle:
        case VDTViolationPolicyNone:
            return policy;
        default:
            return defaultValue;
    }
}

static void appendConfigForApply(NSMutableArray *identifiers,
                                 NSMutableArray *types,
                                 NSMutableArray *percentages,
                                 NSMutableArray *intervals,
                                 NSMutableArray *violationPolicies,
                                 NSDictionary *config,
                                 VDTConfigType type,
                                 BOOL globallyEnabled){
    if (![config isKindOfClass:[NSDictionary class]]){
        return;
    }

    NSString *identifierKey = type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName";
    NSString *identifier = config[identifierKey];
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0){
        return;
    }
    if (type == VDTConfigTypeApp && [identifier isEqualToString:@"com.apple.Preferences"]){
        return;
    }

    BOOL processEnabled = globallyEnabled && [config[@"enabled"] boolValue];
    int percentage = positiveIntValue(config[@"percentage"], 80);
    int interval = positiveIntValue(config[@"interval"], 120);
    VDTViolationPolicy violationPolicy = validViolationPolicy(config[@"violationPolicy"], VDTViolationPolicyMonitorAndTerminate);

    [identifiers addObject:identifier];
    [types addObject:@(type)];
    [percentages addObject:@(processEnabled ? percentage : 0)];
    [intervals addObject:@(processEnabled ? interval : 0)];
    [violationPolicies addObject:@(processEnabled ? violationPolicy : VDTViolationPolicyNone)];
}

static void appendConfigsForApply(NSMutableArray *identifiers,
                                  NSMutableArray *types,
                                  NSMutableArray *percentages,
                                  NSMutableArray *intervals,
                                  NSMutableArray *violationPolicies,
                                  NSDictionary *sourcePrefs,
                                  BOOL globallyEnabled){
    for (NSDictionary *config in safeConfigArray(sourcePrefs, @"appConfigs")){
        appendConfigForApply(identifiers, types, percentages, intervals, violationPolicies, config, VDTConfigTypeApp, globallyEnabled);
    }
    for (NSDictionary *config in safeConfigArray(sourcePrefs, @"daemonConfigs")){
        appendConfigForApply(identifiers, types, percentages, intervals, violationPolicies, config, VDTConfigTypeDaemon, globallyEnabled);
    }
}

static void reloadPrefs(){
    dispatch_async(VedetteApplyQueue(), ^{
        prefs = getPrefs();

        id enabledVal = valueForKeyWithPrefs(@"enabled", prefs);
        BOOL enabled = enabledVal ? [enabledVal boolValue] : YES;

        NSMutableArray *identifiers = [NSMutableArray array];
        NSMutableArray *types = [NSMutableArray array];
        NSMutableArray *percentages = [NSMutableArray array];
        NSMutableArray *intervals = [NSMutableArray array];
        NSMutableArray *violationPolicies = [NSMutableArray array];

        appendConfigsForApply(identifiers, types, percentages, intervals, violationPolicies, prefs, enabled);
        apply_process_configs(identifiers, types, percentages, intervals, violationPolicies);
    });
}

static void restoreAllMonitors(){
    dispatch_async(VedetteApplyQueue(), ^{
        NSDictionary *tmpPrefs = getTempPrefs();

        NSMutableArray *identifiers = [NSMutableArray array];
        NSMutableArray *types = [NSMutableArray array];
        NSMutableArray *percentages = [NSMutableArray array];
        NSMutableArray *intervals = [NSMutableArray array];
        NSMutableArray *violationPolicies = [NSMutableArray array];

        appendConfigsForApply(identifiers, types, percentages, intervals, violationPolicies, tmpPrefs, NO);
        apply_process_configs(identifiers, types, percentages, intervals, violationPolicies);

        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];
    });
}

%ctor{
    @autoreleasepool {
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            
            NSProcessInfo *procInfo = [objc_getClass("NSProcessInfo") processInfo];
            NSArray *args = [procInfo arguments];
            
            if (args.count != 0) {
                
                NSString *executablePath = args[0];
                if (executablePath){
                    
                    BOOL isApplication = ([executablePath rangeOfString:@".app/"].location != NSNotFound);
                    
                    NSString *processName = [executablePath lastPathComponent];
                    
                    if ([processName isEqualToString:@"runningboardd"]){
                        reloadPrefs();
                        notify_register_dispatch(NOTIFY_PID_NN, &notify_pid_token, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int token) {
                            uint64_t pid = 0;
                            notify_get_state(token, &pid);
                            if (pid > 0){
                                dispatch_async(VedetteApplyQueue(), ^{
                                    prefs = getPrefs();
                                    received_new_proc((pid_t)pid);
                                });
                            }
                        });
                        static int notify_rescan_token = 0;
                        notify_register_dispatch(NOTIFY_RESCAN_NN, &notify_rescan_token, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int token) {
                            reloadPrefs();
                        });
                        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VedettePrefsChangedCallback, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VedetteRestoreAllMonitorsCallback, (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                    }else{
                        NSString *bundleIdentifier = isApplication ? [[NSBundle mainBundle] bundleIdentifier] : nil;
                        if(isApplication && [bundleIdentifier isEqualToString:@"com.apple.Preferences"]){
                            HBLogDebug(@"Yeah, just no.");
                            return;
                        }
                        NSDictionary *weakPrefs = getPrefs();
                        id enabledVal = valueForKeyWithPrefs(@"enabled", weakPrefs);
                        BOOL enabled = enabledVal ? [enabledVal boolValue] : YES;
                        BOOL processEnabled = [valueForProcessConfigKeyWithPrefs((isApplication ? bundleIdentifier : processName), @"enabled", @NO, (isApplication ? VDTConfigTypeApp : VDTConfigTypeDaemon), weakPrefs) boolValue];
                        if (enabled && processEnabled){
                            if (!isApplication) {
                                notify_rescan(NOTIFY_RESCAN_NN);
                            }
                            HBLogDebug(@"Notify new pid: %d", [procInfo processIdentifier]);
                            notify_new_pid(NOTIFY_PID_NN, [procInfo processIdentifier]);
                        }
                    }
                    
                }
            }
        });
    }
    
}
