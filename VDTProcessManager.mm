//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "PrivateHeaders.h"

NSDictionary *prefs;

static LSApplicationProxy* appproxy_from_bundle_path(NSString *path){
    return [objc_getClass("LSApplicationProxy") applicationProxyForBundleURL:[NSURL fileURLWithPath:path]];
}

static LSApplicationProxy* appproxy_from_pid(pid_t pid){
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    NSString *possibleBundlePath = [NSString stringWithUTF8String:pathBuffer].stringByDeletingLastPathComponent;
    return appproxy_from_bundle_path(possibleBundlePath);
}

static NSString* name_from_pid(pid_t pid){
    char nameBuffer[256];
    proc_name(pid, nameBuffer, sizeof(nameBuffer));
    return [NSString stringWithUTF8String:nameBuffer];
}

static void write_termdebug_state(NSDictionary *state){
    [state writeToFile:VDT_TERMDEBUG_PATH atomically:YES];
}

/*
static NSArray* all_running_pids(){
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    int *buffer = (int *)malloc(sizeof(int)*n);
    int k = proc_listpids(PROC_ALL_PIDS, 0, buffer, n*sizeof(int));
    
    NSMutableArray *pids = [NSMutableArray array];
    for (int i = 0; i < k; i++) {
        int pid = buffer[i];
        if (pid == 0) continue;
        [pids addObject:@(pid)];
    }
    return pids;
}
*/

NSArray* pids_with_identifier_and_type(NSArray <NSString *>*identifiers, NSArray <NSNumber *> *types){
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    int *buffer = (int *)malloc(sizeof(int)*n);
    int k = proc_listpids(PROC_ALL_PIDS, 0, buffer, n*sizeof(int));
    
    NSMutableArray *pids = [NSMutableArray array];
    for (int i = 0; i < k; i++) {
        int pid = buffer[i];
        if (pid == 0) continue;
        
        LSApplicationProxy *appProxy = appproxy_from_pid(pid);
        
        for (NSUInteger idx = 0; idx < identifiers.count; idx++){
            if ([types[idx] unsignedLongValue] == VDTConfigTypeApp){
                if (appProxy.bundleIdentifier){
                    if ([appProxy.bundleIdentifier isEqualToString:identifiers[idx]]){
                        [pids addObject:@(pid)];
                    }
                }
            }else if ([types[idx] unsignedLongValue] == VDTConfigTypeDaemon && !appProxy.bundleIdentifier){
                NSString *daemonName = name_from_pid(pid);
                if ([daemonName isEqualToString:identifiers[idx]]){
                    [pids addObject:@(pid)];
                }
            }
        }
    }
    return pids; // only existed pids are returned
}

void monitor_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals){
    
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        pid_t pid = [pids[idx] intValue];
        if (pid > 0){
            int percentage = [percentages[idx] intValue];
            int interval = [intervals[idx] intValue];
            
            int beforePercentage = 0;
            int beforeInterval = 0;
            int afterDisablePercentage = 0;
            int afterDisableInterval = 0;
            int afterFatalPercentage = 0;
            int afterFatalInterval = 0;
            
            errno = 0;
            int beforeGetRet = proc_get_cpumon_params(pid, &beforePercentage, &beforeInterval);
            int beforeGetErrno = errno;
            
            errno = 0;
            int disableRet = proc_disable_cpumon(pid);
            int disableErrno = errno;
            
            errno = 0;
            int afterDisableGetRet = proc_get_cpumon_params(pid, &afterDisablePercentage, &afterDisableInterval);
            int afterDisableGetErrno = errno;
            
            int fatalRet = 0;
            int fatalErrno = 0;
            int defaultsRet = 0;
            int defaultsErrno = 0;
            
            if (percentage > 0 && interval > 0){
                errno = 0;
                fatalRet = proc_set_cpumon_params_fatal(pid, percentage, interval);
                fatalErrno = errno;
                if (fatalRet == 0){
                    HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
                }
            }else{
                errno = 0;
                defaultsRet = proc_set_cpumon_defaults(pid);
                defaultsErrno = errno;
                if (defaultsRet == 0){
                    HBLogDebug(@"Restore CPU limits for pid: %d", pid);
                }
            }
            
            errno = 0;
            int afterFatalGetRet = proc_get_cpumon_params(pid, &afterFatalPercentage, &afterFatalInterval);
            int afterFatalGetErrno = errno;
            
            errno = 0;
            int resumeRet = proc_resume_cpumon(pid);
            int resumeErrno = errno;
            
            write_termdebug_state(@{
                @"pid": @(pid),
                @"name": name_from_pid(pid) ?: @"",
                @"requestedPercentage": @(percentage),
                @"requestedInterval": @(interval),
                @"beforeGetRet": @(beforeGetRet),
                @"beforeGetErrno": @(beforeGetErrno),
                @"beforePercentage": @(beforePercentage),
                @"beforeInterval": @(beforeInterval),
                @"disableRet": @(disableRet),
                @"disableErrno": @(disableErrno),
                @"afterDisableGetRet": @(afterDisableGetRet),
                @"afterDisableGetErrno": @(afterDisableGetErrno),
                @"afterDisablePercentage": @(afterDisablePercentage),
                @"afterDisableInterval": @(afterDisableInterval),
                @"fatalRet": @(fatalRet),
                @"fatalErrno": @(fatalErrno),
                @"defaultsRet": @(defaultsRet),
                @"defaultsErrno": @(defaultsErrno),
                @"afterFatalGetRet": @(afterFatalGetRet),
                @"afterFatalGetErrno": @(afterFatalGetErrno),
                @"afterFatalPercentage": @(afterFatalPercentage),
                @"afterFatalInterval": @(afterFatalInterval),
                @"resumeRet": @(resumeRet),
                @"resumeErrno": @(resumeErrno)
            });
        }
    }
}

void throttle_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages){
    
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        pid_t pid = [pids[idx] intValue];
        if (pid > 0){
            int percentage = [percentages[idx] intValue];
            
            if (percentage > 0){
                if (proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage) == 0){
                    HBLogDebug(@"Throttled pid %d with percentage %d%% ", pid, percentage);
                }
            }else{
                if (proc_clear_cpulimits(pid) == 0){
                    HBLogDebug(@"Restored CPU limits for pid %d ", pid);
                }
            }
        }
    }
}

void received_new_proc(pid_t pid){
    
    int percentage = 80;
    int interval = 120;
    
    LSApplicationProxy *appProxy = appproxy_from_pid(pid);
    VDTViolationPolicy violationPolicy = VDTViolationPolicyMonitorAndTerminate;
    
    if (appProxy.bundleIdentifier){ //isApplication
        percentage = [valueForProcessConfigKeyWithPrefs(appProxy.bundleIdentifier, @"percentage", @80, VDTConfigTypeApp, prefs) intValue];
        interval = [valueForProcessConfigKeyWithPrefs(appProxy.bundleIdentifier, @"interval", @120, VDTConfigTypeApp, prefs) intValue];
        violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(appProxy.bundleIdentifier, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), VDTConfigTypeApp, prefs) unsignedLongValue];
    }else{ //isDaemon
        NSString *daemonName = name_from_pid(pid);
        percentage = [valueForProcessConfigKeyWithPrefs(daemonName, @"percentage", @80, VDTConfigTypeDaemon, prefs) intValue];
        interval = [valueForProcessConfigKeyWithPrefs(daemonName, @"interval", @120, VDTConfigTypeDaemon, prefs) intValue];
        violationPolicy = (VDTViolationPolicy)[valueForProcessConfigKeyWithPrefs(daemonName, @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), VDTConfigTypeDaemon, prefs) unsignedLongValue];

    }
    
    switch (violationPolicy) {
        case VDTViolationPolicyMonitorAndTerminate:
            monitor_pids(@[@(pid)], @[@(percentage)], @[@(interval)]);
            break;
        case VDTViolationPolicyThrottle:
            throttle_pids(@[@(pid)], @[@(percentage)]);
            break;
        default:
            break;
    }
}

/*
void restore_all_monitors(){
    NSArray *pids = all_running_pids();
    NSMutableArray *zerosArray = [NSMutableArray array];
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        [zerosArray addObject:@0];
    }
    monitor_pids(pids, zerosArray, zerosArray);
}
*/
