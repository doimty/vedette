//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "PrivateHeaders.h"

NSDictionary *prefs;

static LSApplicationProxy* appproxy_from_bundle_path(NSString *path){
    if (![path isKindOfClass:[NSString class]] || path.length == 0){
        return nil;
    }
    return [objc_getClass("LSApplicationProxy") applicationProxyForBundleURL:[NSURL fileURLWithPath:path]];
}

static LSApplicationProxy* appproxy_from_pid(pid_t pid){
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int ret = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if (ret <= 0 || pathBuffer[0] == '\0'){
        return nil;
    }
    NSString *path = [NSString stringWithUTF8String:pathBuffer];
    if (![path isKindOfClass:[NSString class]] || path.length == 0){
        return nil;
    }
    NSString *possibleBundlePath = path.stringByDeletingLastPathComponent;
    return appproxy_from_bundle_path(possibleBundlePath);
}

static NSString* name_from_pid(pid_t pid){
    char nameBuffer[256] = {0};
    int ret = proc_name(pid, nameBuffer, sizeof(nameBuffer));
    if (ret <= 0 || nameBuffer[0] == '\0'){
        return nil;
    }
    return [NSString stringWithUTF8String:nameBuffer];
}

static NSArray* configsForType(VDTConfigType type, NSDictionary *currentPrefs){
    id configs = currentPrefs[type == VDTConfigTypeApp ? @"appConfigs" : @"daemonConfigs"];
    return [configs isKindOfClass:[NSArray class]] ? configs : @[];
}

static NSDictionary* configForIdentifier(NSString *identifier, VDTConfigType type, NSDictionary *currentPrefs){
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0){
        return nil;
    }
    NSString *identifierKey = type == VDTConfigTypeApp ? @"bundleIdentifier" : @"daemonName";
    for (id entry in configsForType(type, currentPrefs)){
        if (![entry isKindOfClass:[NSDictionary class]]){
            continue;
        }
        NSString *candidate = ((NSDictionary *)entry)[identifierKey];
        if ([candidate isKindOfClass:[NSString class]] && [candidate isEqualToString:identifier]){
            return (NSDictionary *)entry;
        }
    }
    return nil;
}

static int intValueOrDefault(id value, int defaultValue){
    if (!value || ![value respondsToSelector:@selector(intValue)]){
        return defaultValue;
    }
    return [value intValue];
}

static int positiveIntValueOrDefault(id value, int defaultValue){
    int ret = intValueOrDefault(value, defaultValue);
    return ret > 0 ? ret : defaultValue;
}

static VDTViolationPolicy policyValueOrDefault(id value, VDTViolationPolicy defaultValue){
    if (!value || ![value respondsToSelector:@selector(unsignedLongValue)]){
        return defaultValue;
    }
    VDTViolationPolicy policy = (VDTViolationPolicy)[value unsignedLongValue];
    switch (policy) {
        case VDTViolationPolicyNone:
        case VDTViolationPolicyMonitorAndTerminate:
        case VDTViolationPolicyThrottle:
            return policy;
        case VDTViolationPolicyMonitor:
            return VDTViolationPolicyNone;
        default:
            return defaultValue;
    }
}

static void clear_monitor_for_pid(pid_t pid){
    proc_disable_cpumon(pid);
    proc_set_cpumon_defaults(pid);
    proc_resume_cpumon(pid);
}

static void clear_all_limits_for_pid(pid_t pid){
    clear_monitor_for_pid(pid);
    proc_clear_cpulimits(pid);
}

static void apply_policy_to_pid(pid_t pid, VDTViolationPolicy policy, int percentage, int interval){
    if (pid <= 0){
        return;
    }

    switch (policy) {
        case VDTViolationPolicyMonitorAndTerminate:{
            proc_clear_cpulimits(pid);
            proc_disable_cpumon(pid);
            if (percentage > 0 && interval > 0){
                if (proc_set_cpumon_params_fatal(pid, percentage, interval) == 0){
                    HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
                }
            }else{
                proc_set_cpumon_defaults(pid);
            }
            proc_resume_cpumon(pid);
            break;
        }
        case VDTViolationPolicyMonitor:
            clear_all_limits_for_pid(pid);
            break;
        case VDTViolationPolicyThrottle:{
            clear_monitor_for_pid(pid);
            if (percentage > 0){
                if (proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage) == 0){
                    HBLogDebug(@"Throttled pid %d with percentage %d%% ", pid, percentage);
                }
            }else{
                proc_clear_cpulimits(pid);
            }
            break;
        }
        case VDTViolationPolicyNone:
        default:
            clear_all_limits_for_pid(pid);
            break;
    }
}

static void enumerate_running_pids(void (^handler)(pid_t pid)){
    int bufferSize = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bufferSize <= 0){
        return;
    }

    int *buffer = (int *)malloc((size_t)bufferSize);
    if (buffer == NULL){
        return;
    }

    int bytesUsed = proc_listpids(PROC_ALL_PIDS, 0, buffer, bufferSize);
    if (bytesUsed <= 0){
        free(buffer);
        return;
    }

    int pidCount = bytesUsed / (int)sizeof(int);
    for (int i = 0; i < pidCount; i++){
        pid_t pid = (pid_t)buffer[i];
        if (pid > 0){
            handler(pid);
        }
    }
    free(buffer);
}

void apply_process_configs(NSArray <NSString *>*identifiers, NSArray <NSNumber *> *types, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals, NSArray <NSNumber *> *violationPolicies){
    NSUInteger configCount = MIN(MIN(identifiers.count, types.count), MIN(percentages.count, MIN(intervals.count, violationPolicies.count)));
    if (configCount == 0){
        return;
    }

    enumerate_running_pids(^(pid_t pid) {
        LSApplicationProxy *appProxy = appproxy_from_pid(pid);
        NSString *pidIdentifier = nil;
        VDTConfigType pidType = VDTConfigTypeDaemon;

        if (appProxy.bundleIdentifier.length > 0){
            pidIdentifier = appProxy.bundleIdentifier;
            pidType = VDTConfigTypeApp;
        }else{
            pidIdentifier = name_from_pid(pid);
            pidType = VDTConfigTypeDaemon;
        }

        if (![pidIdentifier isKindOfClass:[NSString class]] || pidIdentifier.length == 0){
            return;
        }

        for (NSUInteger idx = 0; idx < configCount; idx++){
            NSString *identifier = identifiers[idx];
            if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0){
                continue;
            }
            if ([types[idx] unsignedLongValue] != pidType){
                continue;
            }
            if (![pidIdentifier isEqualToString:identifier]){
                continue;
            }

            int percentage = intValueOrDefault(percentages[idx], 0);
            int interval = intValueOrDefault(intervals[idx], 0);
            VDTViolationPolicy policy = policyValueOrDefault(violationPolicies[idx], VDTViolationPolicyNone);
            apply_policy_to_pid(pid, policy, percentage, interval);
            break;
        }
    });
}

void received_new_proc(pid_t pid){
    NSDictionary *currentPrefs = prefs ?: getPrefs();
    id enabledVal = valueForKeyWithPrefs(@"enabled", currentPrefs);
    BOOL globallyEnabled = enabledVal ? [enabledVal boolValue] : YES;

    LSApplicationProxy *appProxy = appproxy_from_pid(pid);
    NSString *identifier = nil;
    VDTConfigType type = VDTConfigTypeDaemon;

    if (appProxy.bundleIdentifier.length > 0){
        identifier = appProxy.bundleIdentifier;
        type = VDTConfigTypeApp;
    }else{
        identifier = name_from_pid(pid);
        type = VDTConfigTypeDaemon;
    }

    NSDictionary *config = configForIdentifier(identifier, type, currentPrefs);
    if (!config){
        return;
    }

    BOOL processEnabled = globallyEnabled && [config[@"enabled"] boolValue];
    if (!processEnabled){
        apply_policy_to_pid(pid, VDTViolationPolicyNone, 0, 0);
        return;
    }

    int percentage = positiveIntValueOrDefault(config[@"percentage"], 80);
    int interval = positiveIntValueOrDefault(config[@"interval"], 120);
    VDTViolationPolicy violationPolicy = policyValueOrDefault(config[@"violationPolicy"], VDTViolationPolicyMonitorAndTerminate);
    apply_policy_to_pid(pid, violationPolicy, percentage, interval);
}
