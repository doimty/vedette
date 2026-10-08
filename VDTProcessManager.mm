//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"
#import "PrivateHeaders.h"
#import "VDTProcessIdentity.h"
#import "VDTPolicyTransition.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <os/lock.h>
#include <stdlib.h>

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

#pragma mark - Untrusted plist accessors
//
// The prefs plist is user-writable and can be hand-edited or partially written.
// Every read below is type-checked: an unexpected type must never reach an
// Objective-C selector or a collection literal, because this code runs inside
// runningboardd and an uncaught exception there takes the process down.

static NSArray *vdt_array(id value){
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
}

static NSDictionary *vdt_dictionary(id value){
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSString *vdt_nonEmptyString(id value){
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = (NSString *)value;
    return string.length > 0 ? string : nil;
}

static NSNumber *vdt_number(id value){
    return [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
}

static BOOL vdt_int(id value, int defaultValue, int *outValue){
    if (!outValue) return NO;
    if (!value) {
        *outValue = defaultValue;
        return YES;
    }

    long long parsed = 0;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;

        double numericValue = number.doubleValue;
        parsed = number.longLongValue;
        if (!isfinite(numericValue) || numericValue != (double)parsed) return NO;
    } else if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd) return NO;
    } else {
        return NO;
    }

    if (parsed < INT_MIN || parsed > INT_MAX) return NO;
    *outValue = (int)parsed;
    return YES;
}

static BOOL vdt_bool(id value, BOOL defaultValue){
    if (!value) return defaultValue;
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    return [(NSNumber *)value boolValue];
}

static BOOL vdt_policy(id value, VDTViolationPolicy *outPolicy){
    if (!outPolicy) return NO;
    if (!value) {
        *outPolicy = VDTViolationPolicyMonitorAndTerminate;
        return YES;
    }

    int raw = 0;
    if (!vdt_int(value, 0, &raw)) return NO;
    switch ((VDTViolationPolicy)raw) {
        case VDTViolationPolicyMonitorAndTerminate:
        case VDTViolationPolicyThrottle:
            *outPolicy = (VDTViolationPolicy)raw;
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Process helpers

static LSApplicationProxy* appproxy_from_bundle_path(NSString *path){
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;

    NSURL *bundleURL = nil;
    @try {
        bundleURL = [NSURL fileURLWithPath:path];
    } @catch (NSException *exception) {
        HBLogError(@"Vedette: NSURL exception for path %@: %@ %@", path, exception.name, exception.reason);
        return nil;
    }
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!bundleURL || ![proxyClass respondsToSelector:@selector(applicationProxyForBundleURL:)]) return nil;

    return [proxyClass applicationProxyForBundleURL:bundleURL];
}

static NSString *application_bundle_path_for_executable(NSString *executablePath){
    if (![executablePath isKindOfClass:[NSString class]] || executablePath.length == 0) return nil;

    NSString *candidate = executablePath.stringByDeletingLastPathComponent;
    while (candidate.length > 1) {
        if ([candidate.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame) return candidate;
        NSString *parent = candidate.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:candidate]) break;
        candidate = parent;
    }
    return nil;
}

// Full executable path. Empty string when unavailable, never partial data.
static BOOL executable_path_for_pid(pid_t pid, char *buffer, uint32_t bufferSize){
    return VDTCopyProcessInfoString(pid, buffer, bufferSize, proc_pidpath);
}

// proc_name returns the kernel's possibly truncated p_comm. It is only an exact-
// match fallback when the full executable path is unavailable.
static BOOL proc_comm_for_pid(pid_t pid, char *out, uint32_t outSize){
    return VDTCopyProcessInfoString(pid, out, outSize, proc_name);
}

static BOOL process_instance_token_for_pid(pid_t pid, VDTProcessInstanceToken *outToken){
    if (pid <= 0 || !outToken) return NO;

    struct vdt_proc_bsdinfo info = {};
    int bytes = proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != (int)sizeof(info) || info.pbi_pid != (uint32_t)pid) return NO;

    VDTProcessInstanceToken token = {
        .seconds = info.pbi_start_tvsec,
        .microseconds = info.pbi_start_tvusec
    };
    if (!VDTProcessInstanceTokenIsValid(token)) return NO;

    *outToken = token;
    return YES;
}

#pragma mark - Config normalisation

NSString * const VDTConfigIdentifierKey = @"identifier";
NSString * const VDTConfigTypeKey = @"type";
NSString * const VDTConfigPercentageKey = @"percentage";
NSString * const VDTConfigIntervalKey = @"interval";
NSString * const VDTConfigPolicyKey = @"policy";
NSString * const VDTConfigEnabledKey = @"enabled";
NSString * const VDTTargetPidKey = @"pid";
NSString * const VDTTargetNameKey = @"name";
NSString * const VDTTargetExecutablePathKey = @"executablePath";
NSString * const VDTTargetProcCommKey = @"procComm";
NSString * const VDTTargetStartSecondsKey = @"startSeconds";
NSString * const VDTTargetStartMicrosecondsKey = @"startMicroseconds";

static NSArray<NSDictionary *> *configs_from_section(NSDictionary *prefs,
                                                     NSString *sectionKey,
                                                     NSString *identifierKey,
                                                     VDTConfigType type,
                                                     BOOL globallyEnabled){
    NSMutableArray<NSDictionary *> *configs = [NSMutableArray array];
    NSArray *section = vdt_array(prefs[sectionKey]);

    for (id rawEntry in section) {
        NSDictionary *entry = vdt_dictionary(rawEntry);
        if (!entry) continue;

        NSString *identifier = vdt_nonEmptyString(entry[identifierKey]);
        if (!identifier) continue;

        // The Settings app hosts the preference bundle itself; throttling it
        // would lock the user out of their own configuration.
        if (type == VDTConfigTypeApp && [identifier isEqualToString:@"com.apple.Preferences"]) continue;

        int percentage = 0;
        int interval = 0;
        VDTViolationPolicy policy = VDTViolationPolicyNone;
        BOOL percentageValid = vdt_int(entry[@"percentage"], 80, &percentage);
        BOOL intervalValid = vdt_int(entry[@"interval"], 120, &interval);
        BOOL policyValid = vdt_policy(entry[@"violationPolicy"], &policy);
        BOOL percentageInRange = policy == VDTViolationPolicyThrottle ?
            percentage <= UINT8_MAX : percentage <= 100;
        BOOL parametersValid = percentageValid && percentage > 0 && percentageInRange &&
            policyValid && (policy == VDTViolationPolicyThrottle ||
            (intervalValid && interval > 0));
        BOOL enabled = globallyEnabled && vdt_bool(entry[@"enabled"], NO) && parametersValid;

        [configs addObject:@{
            VDTConfigIdentifierKey: identifier,
            VDTConfigTypeKey: @(type),
            VDTConfigPercentageKey: @(percentageValid ? percentage : 0),
            VDTConfigIntervalKey: @(intervalValid ? interval : 0),
            VDTConfigPolicyKey: @(policyValid ? policy : VDTViolationPolicyNone),
            // Missing values use the preference UI's defaults. Explicitly empty,
            // malformed or non-positive values fail closed instead of turning
            // into an implicit fatal monitor.
            VDTConfigEnabledKey: @(enabled)
        }];
    }

    return configs;
}

NSArray<NSDictionary *>* vdt_configs_from_prefs(NSDictionary *prefs){
    NSDictionary *validatedPrefs = vdt_dictionary(prefs);
    if (!validatedPrefs) return @[];

    BOOL globallyEnabled = vdt_bool(validatedPrefs[@"enabled"], YES);

    NSMutableArray<NSDictionary *> *configs = [NSMutableArray array];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"appConfigs", @"bundleIdentifier",
                                                     VDTConfigTypeApp, globallyEnabled)];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"daemonConfigs", @"daemonName",
                                                     VDTConfigTypeDaemon, globallyEnabled)];
    return configs;
}

#pragma mark - Target resolution

static void split_configs(NSArray<NSDictionary *> *configs,
                         NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById,
                         NSMutableArray<NSDictionary *> *daemonConfigs){
    for (id rawConfig in configs) {
        NSDictionary *config = vdt_dictionary(rawConfig);
        NSString *identifier = vdt_nonEmptyString(config[VDTConfigIdentifierKey]);
        NSNumber *typeValue = vdt_number(config[VDTConfigTypeKey]);
        if (!identifier || !typeValue) continue;

        VDTConfigType type = (VDTConfigType)typeValue.unsignedLongValue;
        if (type == VDTConfigTypeApp) {
            // Preserve the preference API's first-entry-wins behavior if a
            // hand-edited plist contains duplicate identifiers.
            if (!appConfigsById[identifier]) appConfigsById[identifier] = config;
        } else if (type == VDTConfigTypeDaemon) {
            [daemonConfigs addObject:config];
        }
    }
}

// Resolves one PID against the configured set. Returns nil when the process is
// not configured, which is the signal to leave it completely alone.
static NSDictionary *target_for_pid(pid_t pid,
                                    NSDictionary<NSString *, NSDictionary *> *appConfigsById,
                                    NSArray<NSDictionary *> *daemonConfigs){
    if (pid <= 0) return nil;

    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    BOOL hasExecutablePath = executable_path_for_pid(pid, pathBuffer, sizeof(pathBuffer));
    NSString *executablePath = hasExecutablePath ? [NSString stringWithUTF8String:pathBuffer] : nil;
    if (executablePath.length == 0) executablePath = nil;

    char executableName[PROC_PIDPATHINFO_MAXSIZE];
    BOOL hasExecutableName = hasExecutablePath &&
        VDTCopyLastPathComponent(pathBuffer, executableName, sizeof(executableName));

    VDTProcessInstanceToken instanceToken = {};
    if (!process_instance_token_for_pid(pid, &instanceToken)) return nil;

    NSDictionary *matched = nil;
    NSString *matchedName = nil;
    NSString *fallbackProcComm = nil;

    // A verified App identity is authoritative even when that App has no App
    // config. It must never fall through to an unrelated daemon entry that
    // happens to share the executable filename.
    BOOL resolvedAsApplication = NO;
    if (executablePath) {
        NSString *bundlePath = application_bundle_path_for_executable(executablePath);
        resolvedAsApplication = bundlePath != nil;

        if (bundlePath && appConfigsById.count > 0) {
            LSApplicationProxy *appProxy = appproxy_from_bundle_path(bundlePath);
            NSString *bundleIdentifier = appProxy.bundleIdentifier;
            if ([bundleIdentifier isKindOfClass:[NSString class]] && bundleIdentifier.length > 0) {
                resolvedAsApplication = YES;
                NSDictionary *config = appConfigsById[bundleIdentifier];
                if (config) {
                    matched = config;
                    matchedName = bundleIdentifier;
                }
            }
        }
    }

    if (!matched && !resolvedAsApplication && daemonConfigs.count > 0) {
        char procComm[256];
        BOOL hasProcComm = !hasExecutableName && proc_comm_for_pid(pid, procComm, sizeof(procComm));
        if (!hasExecutableName && !hasProcComm) return nil;
        if (hasProcComm) {
            fallbackProcComm = [NSString stringWithUTF8String:procComm];
            if (fallbackProcComm.length == 0) return nil;
        }

        for (NSDictionary *config in daemonConfigs) {
            NSString *configuredName = config[VDTConfigIdentifierKey];
            const char *configured = configuredName.UTF8String;
            if (!configured) continue;
            if (VDTProcessNameMatches(configured,
                                      hasExecutableName ? executableName : NULL,
                                      hasProcComm ? procComm : NULL)) {
                matched = config;
                matchedName = configuredName;
                break;
            }
        }
    }

    if (!matched) return nil;

    NSNumber *typeValue = vdt_number(matched[VDTConfigTypeKey]);
    NSNumber *enabledValue = vdt_number(matched[VDTConfigEnabledKey]);
    if (!typeValue || !enabledValue) return nil;

    BOOL enabled = enabledValue.boolValue;
    NSNumber *percentage = enabled ? vdt_number(matched[VDTConfigPercentageKey]) : @0;
    NSNumber *interval = enabled ? vdt_number(matched[VDTConfigIntervalKey]) : @0;
    NSNumber *policy = enabled ? vdt_number(matched[VDTConfigPolicyKey]) : @(VDTViolationPolicyNone);
    if (!percentage || !interval || !policy) return nil;

    NSMutableDictionary *target = [@{
        VDTTargetPidKey: @(pid),
        VDTTargetNameKey: matchedName ?: @"",
        VDTConfigTypeKey: typeValue,
        // A disabled entry resolves to zero, which the syscall layer treats as
        // "restore system defaults" rather than "apply a fatal limit".
        VDTConfigPercentageKey: percentage,
        VDTConfigIntervalKey: interval,
        VDTConfigPolicyKey: policy,
        VDTTargetStartSecondsKey: @(instanceToken.seconds),
        VDTTargetStartMicrosecondsKey: @(instanceToken.microseconds)
    } mutableCopy];

    // Bind the identity observed during resolution to the target. The syscall
    // layer re-checks it immediately before applying a CPU policy, closing the
    // exited/reused-PID window during a full process scan.
    if (executablePath) {
        target[VDTTargetExecutablePathKey] = executablePath;
    } else if (fallbackProcComm) {
        target[VDTTargetProcCommKey] = fallbackProcComm;
    } else {
        return nil;
    }
    return target;
}

NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs){
    if (configs.count == 0) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *daemonConfigs = [NSMutableArray array];
    split_configs(configs, appConfigsById, daemonConfigs);
    if (appConfigsById.count == 0 && daemonConfigs.count == 0) return @[];

    // proc_listpids reports a byte count, not an element count.
    int listBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (listBytes <= 0) return @[];

    int *buffer = (int *)malloc((size_t)listBytes);
    if (!buffer) return @[];

    int writtenBytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, listBytes);
    if (writtenBytes <= 0) {
        free(buffer);
        return @[];
    }
    if (writtenBytes > listBytes) writtenBytes = listBytes;

    int pidCount = writtenBytes / (int)sizeof(int);
    NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];

    for (int idx = 0; idx < pidCount; idx++) {
        pid_t pid = (pid_t)buffer[idx];
        if (pid <= 0) continue;
        NSDictionary *target = target_for_pid(pid, appConfigsById, daemonConfigs);
        if (target) [targets addObject:target];
    }

    free(buffer);

    VDTProbeRecord(@"runningboardd.resolveTargets", @{
        @"configCount": @(configs.count),
        @"scannedPids": @(pidCount),
        @"matchedTargets": @(targets.count)
    });

    return targets;
}

NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs){
    if (pid <= 0 || configs.count == 0) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *daemonConfigs = [NSMutableArray array];
    split_configs(configs, appConfigsById, daemonConfigs);

    NSDictionary *target = target_for_pid(pid, appConfigsById, daemonConfigs);
    return target ? @[target] : @[];
}

#pragma mark - Monitor / throttle

static BOOL target_instance_token(NSDictionary *target, VDTProcessInstanceToken *outToken){
    if (!outToken) return NO;

    NSNumber *seconds = vdt_number(target[VDTTargetStartSecondsKey]);
    NSNumber *microseconds = vdt_number(target[VDTTargetStartMicrosecondsKey]);
    if (!seconds || !microseconds) return NO;

    VDTProcessInstanceToken token = {
        .seconds = seconds.unsignedLongLongValue,
        .microseconds = microseconds.unsignedLongLongValue
    };
    if (!VDTProcessInstanceTokenIsValid(token)) return NO;

    *outToken = token;
    return YES;
}

static BOOL target_identity_is_current(NSDictionary *target, pid_t pid){
    VDTProcessInstanceToken expectedToken = {};
    VDTProcessInstanceToken beforeToken = {};
    VDTProcessInstanceToken afterToken = {};
    if (!target_instance_token(target, &expectedToken) ||
        !process_instance_token_for_pid(pid, &beforeToken) ||
        !VDTProcessInstanceMatches(expectedToken, beforeToken)) {
        return NO;
    }

    BOOL identityMatches = NO;
    NSString *expectedPath = vdt_nonEmptyString(target[VDTTargetExecutablePathKey]);
    if (expectedPath) {
        char currentPath[PROC_PIDPATHINFO_MAXSIZE];
        if (!executable_path_for_pid(pid, currentPath, sizeof(currentPath))) return NO;

        NSString *current = [NSString stringWithUTF8String:currentPath];
        identityMatches = current.length > 0 && [current isEqualToString:expectedPath];
    } else {
        NSString *expectedComm = vdt_nonEmptyString(target[VDTTargetProcCommKey]);
        if (!expectedComm) return NO;

        char currentComm[256];
        if (!proc_comm_for_pid(pid, currentComm, sizeof(currentComm))) return NO;

        NSString *current = [NSString stringWithUTF8String:currentComm];
        identityMatches = current.length > 0 && [current isEqualToString:expectedComm];
    }
    if (!identityMatches) return NO;

    // Read the lifetime token again after the path/name lookup. If the PID was
    // recycled during identity validation, the two observations cannot both
    // belong to the target instance.
    return process_instance_token_for_pid(pid, &afterToken) &&
        VDTProcessInstanceMatches(expectedToken, afterToken);
}

BOOL vdt_target_instance_is_current(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
    if (!target || !pidValue || pidValue.intValue <= 0) return NO;

    VDTProcessInstanceToken expectedToken = {};
    VDTProcessInstanceToken currentToken = {};
    return target_instance_token(target, &expectedToken) &&
        process_instance_token_for_pid((pid_t)pidValue.intValue, &currentToken) &&
        VDTProcessInstanceMatches(expectedToken, currentToken);
}

BOOL vdt_target_is_current(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
    if (!target || !pidValue || pidValue.intValue <= 0) return NO;
    return target_identity_is_current(target, (pid_t)pidValue.intValue);
}

static bool policy_identity_current(pid_t pid, void *context){
    NSDictionary *target = (__bridge NSDictionary *)context;
    return target_identity_is_current(target, pid);
}

static int policy_clear_cpu_limits(pid_t pid, void *context){
    (void)context;
    return proc_clear_cpulimits(pid);
}

static int policy_disable_cpu_monitor(pid_t pid, void *context){
    (void)context;
    return proc_disable_cpumon(pid);
}

static int policy_set_cpu_monitor_defaults(pid_t pid, void *context){
    (void)context;
    return proc_set_cpumon_defaults(pid);
}

static int policy_resume_cpu_monitor(pid_t pid, void *context){
    (void)context;
    return proc_resume_cpumon(pid);
}

static int policy_set_throttle(pid_t pid, int percentage, void *context){
    (void)context;
    return proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage);
}

static int policy_set_fatal(pid_t pid, int percentage, int interval, void *context){
    (void)context;
    return proc_set_cpumon_params_fatal(pid, percentage, interval);
}

BOOL vdt_apply_target(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
    NSNumber *percentageValue = vdt_number(target[VDTConfigPercentageKey]);
    NSNumber *intervalValue = vdt_number(target[VDTConfigIntervalKey]);
    NSNumber *policyValue = vdt_number(target[VDTConfigPolicyKey]);
    if (!target || !pidValue || !percentageValue || !intervalValue || !policyValue) return NO;

    pid_t pid = (pid_t)pidValue.intValue;
    if (pid <= 0) return NO;

    int percentage = percentageValue.intValue;
    int interval = intervalValue.intValue;
    VDTViolationPolicy policy = (VDTViolationPolicy)policyValue.unsignedLongValue;
    VDTPolicyMode mode = VDTPolicyModeRestore;
    if (policy == VDTViolationPolicyThrottle && percentage > 0 && percentage <= UINT8_MAX) {
        mode = VDTPolicyModeThrottle;
    } else if (policy == VDTViolationPolicyMonitorAndTerminate &&
               percentage > 0 && percentage <= 100 && interval > 0) {
        mode = VDTPolicyModeFatal;
    }

    VDTPolicyOperations operations = {
        .identityCurrent = policy_identity_current,
        .clearCpuLimits = policy_clear_cpu_limits,
        .disableCpuMonitor = policy_disable_cpu_monitor,
        .setCpuMonitorDefaults = policy_set_cpu_monitor_defaults,
        .resumeCpuMonitor = policy_resume_cpu_monitor,
        .setThrottle = policy_set_throttle,
        .setFatal = policy_set_fatal,
        .context = (__bridge void *)target
    };

    errno = 0;
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        pid, mode, percentage, interval, &operations);
#if VDT_DIAGNOSTICS_ENABLED
    int operationErrno = errno;
#endif

    if (result.identityRejected) {
        VDTProbeRecord(@"runningboardd.targetSkipped", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"reason": @"identityChangedOrUnavailable"
        });
    }

    if (mode == VDTPolicyModeThrottle) {
        if (result.success) {
            HBLogDebug(@"Throttled pid %d with percentage %d%%", pid, percentage);
        }
        VDTProbeRecord(@"runningboardd.throttleSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"requestedPercentage": @(percentage),
            @"disableRet": @(result.disableResult),
            @"defaultsRet": @(result.defaultsResult),
            @"resumeRet": @(result.resumeResult),
            @"setRet": @(result.applyResult),
            @"retirementFailed": @(result.retirementFailed),
            @"identityRejected": @(result.identityRejected),
            @"errno": @(operationErrno)
        });
    } else if (mode == VDTPolicyModeFatal) {
        if (result.success) {
            HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
        }
        VDTProbeRecord(@"runningboardd.monitorSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"percentage": @(percentage),
            @"interval": @(interval),
            @"clearRet": @(result.clearResult),
            @"disableRet": @(result.disableResult),
            @"setRet": @(result.applyResult),
            @"resumeRet": @(result.resumeResult),
            @"retirementFailed": @(result.retirementFailed),
            @"identityRejected": @(result.identityRejected),
            @"errno": @(operationErrno)
        });
    } else {
        if (result.success) HBLogDebug(@"Restored CPU limits for pid %d", pid);
        VDTProbeRecord(@"runningboardd.restoreSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"clearRet": @(result.clearResult),
            @"disableRet": @(result.disableResult),
            @"defaultsRet": @(result.defaultsResult),
            @"resumeRet": @(result.resumeResult),
            @"identityRejected": @(result.identityRejected),
            @"errno": @(operationErrno)
        });
    }

    return result.success;
}

void vdt_apply_targets(NSArray<NSDictionary *> *targets){
    for (id target in targets) {
        vdt_apply_target(target);
    }
}
