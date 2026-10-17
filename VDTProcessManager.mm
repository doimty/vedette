//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"
#import "PrivateHeaders.h"

#include <os/lock.h>
#include <sys/proc_info.h>
#include "libproc/VDTPIDList.h"
#include "libproc/VDTRulePolicy.h"

#pragma mark - Thread-safe prefs storage

static NSDictionary *_prefs;
static os_unfair_lock _prefsLock = OS_UNFAIR_LOCK_INIT;

void VDTSetPrefs(NSDictionary *newPrefs){
    os_unfair_lock_lock(&_prefsLock);
    _prefs = newPrefs;
    os_unfair_lock_unlock(&_prefsLock);
}

NSDictionary *VDTGetPrefs(void){
    os_unfair_lock_lock(&_prefsLock);
    NSDictionary *snapshot = _prefs;
    os_unfair_lock_unlock(&_prefsLock);
    return snapshot;
}

#pragma mark - Process helpers

#define VDT_PID_SNAPSHOT_MAX_ATTEMPTS 4
#define VDT_PID_SNAPSHOT_SLACK 16

typedef struct {
    uint64_t seconds;
    uint64_t microseconds;
} VDTProcessStartTime;

static NSMutableDictionary<NSNumber *, NSDictionary *> *VDTManagedProcessRules;

static LSApplicationProxy *appproxy_from_bundle_path(NSString *path){
    if (!path.length) return nil;
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!proxyClass) return nil;
    return [proxyClass applicationProxyForBundleURL:[NSURL fileURLWithPath:path]];
}

static LSApplicationProxy *appproxy_from_pid(pid_t pid){
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if (pathLength <= 0) return nil;
    pathBuffer[sizeof(pathBuffer) - 1] = '\0';
    NSString *executablePath = [NSString stringWithUTF8String:pathBuffer];
    if (!executablePath.length) return nil;
    NSString *bundlePath = executablePath.stringByDeletingLastPathComponent;
    NSString *bundleExtension = bundlePath.pathExtension.lowercaseString;
    if (![bundleExtension isEqualToString:@"app"]
        && ![bundleExtension isEqualToString:@"appex"])
        return nil;
    return appproxy_from_bundle_path(bundlePath);
}

static NSString *name_from_pid(pid_t pid){
    char nameBuffer[256] = {0};
    int nameLength = proc_name(pid, nameBuffer, sizeof(nameBuffer));
    if (nameLength <= 0) return nil;
    nameBuffer[sizeof(nameBuffer) - 1] = '\0';
    return [NSString stringWithUTF8String:nameBuffer];
}

static BOOL VDTReadProcessStartTime(pid_t pid, VDTProcessStartTime *startTime){
    if (pid <= 0 || !startTime) return NO;
    struct proc_bsdinfo info = {0};
    int result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (result != sizeof(info) || info.pbi_pid != (uint32_t)pid) return NO;
    startTime->seconds = info.pbi_start_tvsec;
    startTime->microseconds = info.pbi_start_tvusec;
    return YES;
}

static pid_t *VDTCreatePIDSnapshot(size_t *pidCountOut){
    if (!pidCountOut) return NULL;
    *pidCountOut = 0;

    int probedBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    size_t probedCount = VDTPIDCountFromBytes(probedBytes);
    if (!probedCount || probedCount > SIZE_MAX - VDT_PID_SNAPSHOT_SLACK) return NULL;

    size_t capacity = probedCount + VDT_PID_SNAPSHOT_SLACK;
    for (unsigned attempt = 0; attempt < VDT_PID_SNAPSHOT_MAX_ATTEMPTS; attempt++){
        int byteCapacity = 0;
        if (!VDTCapacityBytesForPIDCount(capacity, &byteCapacity)) return NULL;

        pid_t *buffer = (pid_t *)malloc((size_t)byteCapacity);
        if (!buffer) return NULL;

        int returnedBytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, byteCapacity);
        if (returnedBytes <= 0){
            free(buffer);
            return NULL;
        }
        if (VDTNeedsPIDSnapshotRetry(returnedBytes, byteCapacity)){
            free(buffer);
            size_t nextCapacity = 0;
            if (attempt + 1 == VDT_PID_SNAPSHOT_MAX_ATTEMPTS
                || !VDTGrowPIDCapacity(capacity, &nextCapacity))
                return NULL;
            capacity = nextCapacity;
            continue;
        }

        size_t pidCount = VDTPIDCountFromBytes(returnedBytes);
        if (!pidCount || pidCount > capacity){
            free(buffer);
            return NULL;
        }
        *pidCountOut = pidCount;
        return buffer;
    }
    return NULL;
}

static BOOL VDTProcessStartTimeMatchesRecord(pid_t pid, NSDictionary *record){
    VDTProcessStartTime startTime = {0};
    if (!VDTReadProcessStartTime(pid, &startTime)) return NO;
    return startTime.seconds == [record[@"startSeconds"] unsignedLongLongValue]
        && startTime.microseconds == [record[@"startMicroseconds"] unsignedLongLongValue];
}

static BOOL VDTGlobalMonitoringEnabled(NSDictionary *prefs){
    id value = prefs[@"enabled"];
    if (!value) return YES;
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    return [value boolValue];
}

static NSDictionary *VDTRuleIndex(NSArray *configs, NSString *identifierKey, BOOL globalEnabled){
    NSMutableDictionary *rules = [NSMutableDictionary dictionary];
    if (![configs isKindOfClass:[NSArray class]]) return rules;

    for (id entry in configs){
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *config = entry;
        id identifier = config[identifierKey];
        if (![identifier isKindOfClass:[NSString class]] || ![identifier length]
            || rules[identifier]
            || ([identifierKey isEqualToString:@"bundleIdentifier"]
                && [identifier isEqualToString:@"com.apple.Preferences"]))
            continue;

        id enabledValue = config[@"enabled"];
        BOOL processEnabled = [enabledValue isKindOfClass:[NSNumber class]]
            && [enabledValue boolValue];
        id policyValue = config[@"violationPolicy"];
        NSInteger policy = !policyValue ? VDTViolationPolicyMonitorAndTerminate
            : [policyValue isKindOfClass:[NSNumber class]] ? [policyValue integerValue] : -1;
        id percentageValue = config[@"percentage"];
        NSInteger percentage = !percentageValue ? 80
            : [percentageValue isKindOfClass:[NSNumber class]] ? [percentageValue integerValue] : 0;
        id intervalValue = config[@"interval"];
        NSInteger interval = !intervalValue ? 120
            : [intervalValue isKindOfClass:[NSNumber class]] ? [intervalValue integerValue] : 0;
        NSString *signature = [NSString stringWithFormat:@"%d:%d:%ld:%ld:%ld",
                               globalEnabled, processEnabled, (long)policy,
                               (long)percentage, (long)interval];
        rules[identifier] = @{
            @"enabled": @(processEnabled),
            @"policy": @(policy),
            @"percentage": @(percentage),
            @"interval": @(interval),
            @"signature": signature
        };
    }
    return [rules copy];
}

static NSDictionary *VDTRuleForPID(pid_t pid,
                                   NSDictionary *appRules,
                                   NSDictionary *daemonRules,
                                   NSString **identifierOut,
                                   VDTConfigType *typeOut){
    if (daemonRules.count){
        NSString *processName = name_from_pid(pid);
        NSDictionary *rule = processName ? daemonRules[processName] : nil;
        if (rule){
            if (identifierOut) *identifierOut = processName;
            if (typeOut) *typeOut = VDTConfigTypeDaemon;
            return rule;
        }
    }
    if (appRules.count){
        LSApplicationProxy *appProxy = appproxy_from_pid(pid);
        NSString *bundleIdentifier = appProxy.bundleIdentifier;
        NSDictionary *rule = bundleIdentifier ? appRules[bundleIdentifier] : nil;
        if (rule){
            if (identifierOut) *identifierOut = bundleIdentifier;
            if (typeOut) *typeOut = VDTConfigTypeApp;
            return rule;
        }
    }
    return nil;
}

static void VDTApplyProcessAction(pid_t pid, VDTCPUAction action,
                                  NSInteger percentage, NSInteger interval){
    NSArray *pids = @[@(pid)];
    switch (action){
        case VDTCPUActionMonitorAndTerminate:
            throttle_pids(pids, @[@0]);
            monitor_pids(pids, @[@(percentage)], @[@(interval)]);
            break;
        case VDTCPUActionThrottle:
            monitor_pids(pids, @[@0], @[@0]);
            throttle_pids(pids, @[@(percentage)]);
            break;
        case VDTCPUActionNone:
        default:
            monitor_pids(pids, @[@0], @[@0]);
            throttle_pids(pids, @[@0]);
            break;
    }
}

#pragma mark - Monitor / throttle

void monitor_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals){
    
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        pid_t pid = [pids[idx] intValue];
        if (pid > 0){
            int percentage = [percentages[idx] intValue];
            int interval = [intervals[idx] intValue];
            int disableRet = proc_disable_cpumon(pid);
            int setRet = -999;
            int resumeRet = -999;
            
            if (percentage > 0 && interval > 0){
                setRet = proc_set_cpumon_params_fatal(pid, percentage, interval);
                if (setRet == 0){
                    HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
                }
            }else{
                setRet = proc_set_cpumon_defaults(pid);
                if (setRet == 0){
                    HBLogDebug(@"Restore CPU limits for pid: %d", pid);
                }
            }
            
            resumeRet = proc_resume_cpumon(pid);
            
            VDTProbeRecord(@"runningboardd.monitorSyscall", @{
                @"pid": @(pid),
                @"name": name_from_pid(pid) ?: @"",
                @"percentage": @(percentage),
                @"interval": @(interval),
                @"disableRet": @(disableRet),
                @"setRet": @(setRet),
                @"resumeRet": @(resumeRet)
            });
        }
    }
}

void throttle_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages){
    
    for (NSUInteger idx = 0; idx < pids.count; idx++){
        pid_t pid = [pids[idx] intValue];
        if (pid > 0){
            int percentage = [percentages[idx] intValue];
            int setRet = 0;
            int clearRet = 0;
            
            if (percentage > 0){
                errno = 0;
                setRet = proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage);
                if (setRet == 0){
                    HBLogDebug(@"Throttled pid %d with percentage %d%% ", pid, percentage);
                }
            }else{
                errno = 0;
                clearRet = proc_clear_cpulimits(pid);
                if (clearRet == 0){
                    HBLogDebug(@"Restored CPU limits for pid %d ", pid);
                }
            }
            
            VDTProbeRecord(@"runningboardd.throttleSyscall", @{
                @"pid": @(pid),
                @"name": name_from_pid(pid) ?: @"",
                @"requestedPercentage": @(percentage),
                @"setRet": @(setRet),
                @"setErrno": @(errno),
                @"clearRet": @(clearRet)
            });
        }
    }
}

#pragma mark - Process rule reconciliation

static NSMutableDictionary<NSNumber *, NSDictionary *> *VDTManagedRules(void){
    if (!VDTManagedProcessRules) VDTManagedProcessRules = [NSMutableDictionary dictionary];
    return VDTManagedProcessRules;
}

static BOOL VDTProcessRecordMatches(NSDictionary *record,
                                    VDTProcessStartTime startTime,
                                    NSString *identifier,
                                    VDTConfigType type,
                                    NSString *signature){
    return startTime.seconds == [record[@"startSeconds"] unsignedLongLongValue]
        && startTime.microseconds == [record[@"startMicroseconds"] unsignedLongLongValue]
        && [record[@"identifier"] isEqualToString:identifier]
        && [record[@"type"] unsignedLongValue] == (unsigned long)type
        && [record[@"signature"] isEqualToString:signature];
}

static VDTCPUAction VDTActionForRule(NSDictionary *rule, BOOL globalEnabled){
    return VDTResolveCPUAction(globalEnabled,
                               rule != nil,
                               [rule[@"enabled"] boolValue],
                               [rule[@"policy"] intValue],
                               VDTViolationPolicyMonitorAndTerminate,
                               VDTViolationPolicyThrottle,
                               [rule[@"percentage"] intValue],
                               [rule[@"interval"] intValue]);
}

static void VDTRestoreManagedRules(NSDictionary *livePIDs){
    NSMutableDictionary *managedRules = VDTManagedRules();
    for (NSNumber *pidNumber in [managedRules.allKeys copy]){
        if (![livePIDs containsObject:pidNumber]) continue;
        pid_t pid = (pid_t)[pidNumber intValue];
        NSDictionary *record = managedRules[pidNumber];
        if (!VDTProcessStartTimeMatchesRecord(pid, record)) continue;
        VDTApplyProcessAction(pid, VDTCPUActionNone, 0, 0);
    }
    [managedRules removeAllObjects];
}

void VDTReconcileProcessRules(NSDictionary *prefs, BOOL force){
    if (![prefs isKindOfClass:[NSDictionary class]]) return;

    BOOL globalEnabled = VDTGlobalMonitoringEnabled(prefs);
    NSDictionary *appRules = VDTRuleIndex(prefs[@"appConfigs"], @"bundleIdentifier", globalEnabled);
    NSDictionary *daemonRules = VDTRuleIndex(prefs[@"daemonConfigs"], @"daemonName", globalEnabled);

    size_t pidCount = 0;
    pid_t *pids = VDTCreatePIDSnapshot(&pidCount);
    if (!pids) return;

    NSMutableSet *livePIDs = [NSMutableSet setWithCapacity:pidCount];
    for (size_t index = 0; index < pidCount; index++)
        if (pids[index] > 0) [livePIDs addObject:@(pids[index])];

    NSMutableDictionary *managedRules = VDTManagedRules();
    if (force) {
        VDTRestoreManagedRules(livePIDs);
    }

    NSMutableSet *matchedPIDs = [NSMutableSet set];
    for (size_t index = 0; index < pidCount; index++){
        pid_t pid = pids[index];
        if (pid <= 0) continue;

        NSNumber *pidNumber = @(pid);
        NSString *identifier = nil;
        VDTConfigType type = VDTConfigTypeApp;
        NSDictionary *rule = VDTRuleForPID(pid, appRules, daemonRules, &identifier, &type);
        if (!rule) {
            [managedRules removeObjectForKey:pidNumber];
            continue;
        }
        [matchedPIDs addObject:pidNumber];

        VDTProcessStartTime startTime = {0};
        if (!VDTReadProcessStartTime(pid, &startTime)) continue;

        NSString *signature = rule[@"signature"];
        NSDictionary *oldRecord = managedRules[pidNumber];
        BOOL unchanged = oldRecord
            && VDTProcessRecordMatches(oldRecord, startTime, identifier, type, signature);
        if (!force && unchanged) continue;

        VDTCPUAction action = VDTActionForRule(rule, globalEnabled);
        if (!force && action == VDTCPUActionNone) {
            [managedRules removeObjectForKey:pidNumber];
            continue;
        }

        NSString *confirmedIdentifier = nil;
        VDTConfigType confirmedType = VDTConfigTypeApp;
        NSDictionary *confirmedRule = VDTRuleForPID(pid, appRules, daemonRules,
                                                     &confirmedIdentifier, &confirmedType);
        if (!confirmedRule || ![confirmedIdentifier isEqualToString:identifier]
            || confirmedType != type
            || ![confirmedRule[@"signature"] isEqualToString:signature])
            continue;

        VDTProcessStartTime confirmedStartTime = {0};
        if (!VDTReadProcessStartTime(pid, &confirmedStartTime)
            || confirmedStartTime.seconds != startTime.seconds
            || confirmedStartTime.microseconds != startTime.microseconds)
            continue;

        action = VDTActionForRule(confirmedRule, globalEnabled);
        VDTApplyProcessAction(pid, action,
                              [confirmedRule[@"percentage"] integerValue],
                              [confirmedRule[@"interval"] integerValue]);
        if (action == VDTCPUActionNone) {
            [managedRules removeObjectForKey:pidNumber];
            continue;
        }

        managedRules[pidNumber] = @{
            @"startSeconds": @(startTime.seconds),
            @"startMicroseconds": @(startTime.microseconds),
            @"identifier": identifier,
            @"type": @(type),
            @"signature": signature
        };
        VDTProbeRecord(@"runningboardd.processRuleApplied", @{
            @"pid": pidNumber,
            @"identifier": identifier,
            @"type": @(type),
            @"action": @(action)
        });
    }

    for (NSNumber *pidNumber in [managedRules.allKeys copy])
        if (![livePIDs containsObject:pidNumber] || ![matchedPIDs containsObject:pidNumber])
            [managedRules removeObjectForKey:pidNumber];

    free(pids);
}

void VDTRestoreProcessesMatchingPrefs(NSDictionary *prefs){
    if (![prefs isKindOfClass:[NSDictionary class]]) return;
    BOOL globalEnabled = VDTGlobalMonitoringEnabled(prefs);
    NSDictionary *appRules = VDTRuleIndex(prefs[@"appConfigs"], @"bundleIdentifier", globalEnabled);
    NSDictionary *daemonRules = VDTRuleIndex(prefs[@"daemonConfigs"], @"daemonName", globalEnabled);
    if (!appRules.count && !daemonRules.count) return;

    size_t pidCount = 0;
    pid_t *pids = VDTCreatePIDSnapshot(&pidCount);
    if (!pids) return;

    for (size_t index = 0; index < pidCount; index++){
        pid_t pid = pids[index];
        if (pid <= 0) continue;
        NSString *identifier = nil;
        VDTConfigType type = VDTConfigTypeApp;
        NSDictionary *rule = VDTRuleForPID(pid, appRules, daemonRules, &identifier, &type);
        if (!rule) continue;

        VDTProcessStartTime startTime = {0};
        if (!VDTReadProcessStartTime(pid, &startTime)) continue;
        NSString *confirmedIdentifier = nil;
        VDTConfigType confirmedType = VDTConfigTypeApp;
        if (!VDTRuleForPID(pid, appRules, daemonRules, &confirmedIdentifier, &confirmedType)
            || confirmedType != type || ![confirmedIdentifier isEqualToString:identifier]
            || !VDTProcessStartTimeMatchesRecord(pid, @{
                @"startSeconds": @(startTime.seconds),
                @"startMicroseconds": @(startTime.microseconds)
            }))
            continue;
        VDTApplyProcessAction(pid, VDTCPUActionNone, 0, 0);
    }
    free(pids);
}
