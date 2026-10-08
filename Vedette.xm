//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"
#import "VDTProcessIdentity.h"
#import "VDTNiceRuntime.h"
#import "VDTNiceShared.h"

#include <limits.h>
#include <notify.h>
#include <unistd.h>

#pragma mark - Serial queue for prefs/monitoring work
// All prefs reload and process scanning work is serialized here to prevent
// concurrent reloadPrefs calls from racing on PID lookups and syscalls.

static dispatch_queue_t vedette_serial_queue(){
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.udevs.vedette.serial", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

#pragma mark - Darwin notification helpers

// PID state is only a fast path. Darwin notifications may coalesce, so
// runningboardd also performs a debounced scan for configured instances that
// were not represented by the last state value.
static void notify_new_pid(const char *notificationName, uint64_t pid){
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int token = 0;
        if (notify_register_check(notificationName, &token) == NOTIFY_STATUS_OK) {
            // State is optional acceleration. The name-only post still triggers
            // runningboardd's full catch-up scan if state storage fails.
            notify_set_state(token, pid);
            notify_cancel(token);
        }
        notify_post(notificationName);
    });
}

#pragma mark runningboardd

static int notify_pid_token;
static BOOL launch_catch_up_scheduled;

static NSMutableSet<NSString *> *tracked_process_instances(){
    static dispatch_once_t once;
    static NSMutableSet<NSString *> *instances;
    dispatch_once(&once, ^{
        instances = [NSMutableSet set];
    });
    return instances;
}

static NSMutableDictionary<NSString *, NSDictionary *> *managed_process_targets(){
    static dispatch_once_t once;
    static NSMutableDictionary<NSString *, NSDictionary *> *targets;
    dispatch_once(&once, ^{
        targets = [NSMutableDictionary dictionary];
    });
    return targets;
}

// This snapshot is confined to vedette_serial_queue. It contains only the
// validated configuration, never a PID-lifetime proof; target identity is
// still rechecked immediately before each policy syscall.
static NSArray<NSDictionary *> *normalized_configs_snapshot;

static NSArray<NSDictionary *> *current_normalized_configs_sync(void){
    if (!normalized_configs_snapshot){
        normalized_configs_snapshot = [vdt_configs_from_prefs(VDTGetPrefs()) copy];
    }
    return normalized_configs_snapshot;
}

static NSString *target_instance_key(NSDictionary *target){
    NSNumber *pid = [target[VDTTargetPidKey] isKindOfClass:[NSNumber class]] ? target[VDTTargetPidKey] : nil;
    NSNumber *seconds = [target[VDTTargetStartSecondsKey] isKindOfClass:[NSNumber class]] ? target[VDTTargetStartSecondsKey] : nil;
    NSNumber *microseconds = [target[VDTTargetStartMicrosecondsKey] isKindOfClass:[NSNumber class]] ? target[VDTTargetStartMicrosecondsKey] : nil;
    NSString *identity = [target[VDTTargetExecutablePathKey] isKindOfClass:[NSString class]] ? target[VDTTargetExecutablePathKey] : nil;
    if (!identity) {
        identity = [target[VDTTargetProcCommKey] isKindOfClass:[NSString class]] ? target[VDTTargetProcCommKey] : nil;
    }
    if (pid.intValue <= 0 || !seconds || !microseconds || identity.length == 0) return nil;

    return [NSString stringWithFormat:@"%d:%llu:%llu:%@",
            pid.intValue,
            seconds.unsignedLongLongValue,
            microseconds.unsignedLongLongValue,
            identity];
}

static BOOL target_has_enabled_policy(NSDictionary *target){
    NSNumber *policy = [target[VDTConfigPolicyKey] isKindOfClass:[NSNumber class]] ? target[VDTConfigPolicyKey] : nil;
    if (!policy) return NO;

    VDTViolationPolicy value = (VDTViolationPolicy)policy.unsignedLongValue;
    return value == VDTViolationPolicyMonitorAndTerminate ||
        value == VDTViolationPolicyThrottle;
}

static void apply_launch_target_if_needed(NSDictionary *target){
    // Nice has independent success/retry tracking; CPU dedup must not hide it.
    vdt_nice_apply(target);
    NSString *instanceKey = target_instance_key(target);
    if (!instanceKey || [tracked_process_instances() containsObject:instanceKey]) return;

    // A newly launched disabled target starts from system defaults. If this
    // instance was previously managed, however, explicitly retire that policy.
    if (!target_has_enabled_policy(target)) {
        if (!managed_process_targets()[instanceKey] || vdt_apply_target(target)) {
            [managed_process_targets() removeObjectForKey:instanceKey];
            [tracked_process_instances() addObject:instanceKey];
        }
        return;
    }

    // Record every target that may have been touched, including a partial
    // transition, so deleting its config can still trigger a later restore.
    managed_process_targets()[instanceKey] = target;
    if (vdt_apply_target(target)) {
        [tracked_process_instances() addObject:instanceKey];
    }
}

static NSString *config_identity_key(NSNumber *type, NSString *identifier){
    if (![type isKindOfClass:[NSNumber class]] ||
        ![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%lu:%@", (unsigned long)type.unsignedLongValue, identifier];
}

static NSSet<NSString *> *active_config_keys(NSArray<NSDictionary *> *configs){
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *config in configs) {
        NSString *key = config_identity_key(config[VDTConfigTypeKey], config[VDTConfigIdentifierKey]);
        if (!key || [seen containsObject:key]) continue;
        [seen addObject:key];

        NSNumber *enabled = [config[VDTConfigEnabledKey] isKindOfClass:[NSNumber class]] ?
            config[VDTConfigEnabledKey] : nil;
        if (enabled.boolValue) [keys addObject:key];
    }
    return keys;
}

static void retire_targets_without_active_config(NSArray<NSDictionary *> *configs){
    NSSet<NSString *> *activeKeys = active_config_keys(configs);
    for (NSString *instanceKey in [managed_process_targets().allKeys copy]) {
        NSDictionary *oldTarget = managed_process_targets()[instanceKey];
        if (!vdt_target_instance_is_current(oldTarget)) {
            [managed_process_targets() removeObjectForKey:instanceKey];
            [tracked_process_instances() removeObject:instanceKey];
            continue;
        }

        NSString *configKey = config_identity_key(oldTarget[VDTConfigTypeKey],
                                                   oldTarget[VDTTargetNameKey]);
        if (configKey && [activeKeys containsObject:configKey]) continue;

        if (!vdt_target_is_current(oldTarget)) {
            // The PID lifetime still matches, but identity is temporarily
            // unavailable or changed. Keep the record and retry; never clean a
            // target whose bound executable cannot be proved current.
            continue;
        }

        NSMutableDictionary *restoreTarget = [oldTarget mutableCopy];
        restoreTarget[VDTConfigPercentageKey] = @0;
        restoreTarget[VDTConfigIntervalKey] = @0;
        restoreTarget[VDTConfigPolicyKey] = @(VDTViolationPolicyNone);
        if (vdt_apply_target(restoreTarget)) {
            [managed_process_targets() removeObjectForKey:instanceKey];
            [tracked_process_instances() removeObject:instanceKey];
        }
    }
}

static void reconcile_unreported_processes_sync(){
    NSArray<NSDictionary *> *configs = current_normalized_configs_sync();
    NSArray<NSDictionary *> *targets = vdt_resolve_targets(configs);
    NSMutableSet<NSString *> *liveInstances = [NSMutableSet set];

    retire_targets_without_active_config(configs);
    vdt_nice_reconcile();
    for (NSDictionary *target in targets) {
        NSString *instanceKey = target_instance_key(target);
        if (instanceKey) [liveInstances addObject:instanceKey];
        apply_launch_target_if_needed(target);
    }

    // Forget exited instances so a reused PID with a new start-time token is
    // independently eligible on the next launch signal.
    [tracked_process_instances() intersectSet:liveInstances];
    vdt_nice_publish();
}

static void schedule_launch_catch_up_sync(){
    if (launch_catch_up_scheduled) return;
    launch_catch_up_scheduled = YES;

    // Scan once immediately for PIDs whose shared state was overwritten, then
    // once at the trailing edge for launches coalesced during this burst.
    reconcile_unreported_processes_sync();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   vedette_serial_queue(), ^{
        launch_catch_up_scheduled = NO;
        reconcile_unreported_processes_sync();
    });
}

static void handle_reported_pid_sync(pid_t pid){
    NSArray<NSDictionary *> *configs = current_normalized_configs_sync();
    NSArray<NSDictionary *> *targets = vdt_targets_for_pid(pid, configs);

    if (targets.count == 0) {
        VDTProbeRecord(@"runningboardd.receivedNewProcSkipped", @{
            @"pid": @(pid),
            @"reason": @"notConfigured"
        });
    } else {
        apply_launch_target_if_needed(targets.firstObject);
    }
    schedule_launch_catch_up_sync();
}

// Core prefs reload logic. Must be called on vedette_serial_queue.
static void reloadPrefsSync(){
    NSDictionary *newPrefs = getPrefs();
    NSArray<NSDictionary *> *configs = vdt_configs_from_prefs(newPrefs);
    VDTSetPrefs(newPrefs);
    normalized_configs_snapshot = [configs copy];
    vdt_nice_reload(newPrefs);

    NSArray<NSDictionary *> *targets = vdt_resolve_targets(configs);
    HBLogDebug(@"Vedette configs: %@", configs);
    HBLogDebug(@"Vedette targets: %@", targets);

    retire_targets_without_active_config(configs);
    vdt_nice_reconcile();
    [tracked_process_instances() removeAllObjects];
    for (NSDictionary *target in targets) {
        vdt_nice_apply(target);
        NSString *instanceKey = target_instance_key(target);
        if (!instanceKey) continue;

        BOOL enabled = target_has_enabled_policy(target);
        BOOL success = YES;
        if (enabled) {
            managed_process_targets()[instanceKey] = target;
            success = vdt_apply_target(target);
        } else if (managed_process_targets()[instanceKey]) {
            success = vdt_apply_target(target);
            if (success) [managed_process_targets() removeObjectForKey:instanceKey];
        }
        if (success) [tracked_process_instances() addObject:instanceKey];
    }
    vdt_nice_publish();
}

// Async wrapper — safe to call from any context (CFNotificationCallback, etc.)
static void reloadPrefs(){
    dispatch_async(vedette_serial_queue(), ^{
        reloadPrefsSync();
    });
}

static void restoreAllMonitors(){
    dispatch_async(vedette_serial_queue(), ^{
        // Nice restore follows the CURRENT saved settings, never a public
        // notification alone. Its durable records do not depend on the CPU temp file.
        vdt_nice_reload(getPrefs());
        vdt_nice_reconcile();
        vdt_nice_publish();
        // Force every entry from the uninstall snapshot to disabled, so each
        // resolved target takes the restore path and hands the process back to
        // the system. The previous implementation inferred app-vs-daemon from an
        // index comparison that mis-typed daemon entries whenever both sections
        // were populated.
        NSArray<NSDictionary *> *configs = vdt_configs_from_prefs(getTempPrefs());
        NSMutableArray<NSDictionary *> *restoreConfigs = [NSMutableArray array];
        for (NSDictionary *config in configs){
            NSMutableDictionary *restore = [config mutableCopy];
            restore[VDTConfigEnabledKey] = @NO;
            [restoreConfigs addObject:restore];
        }

        vdt_apply_targets(vdt_resolve_targets(restoreConfigs));
        [tracked_process_instances() removeAllObjects];
        [managed_process_targets() removeAllObjects];

        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];
    });
}

static void prefsChangedCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo){
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    reloadPrefs();
}

static void restoreAllMonitorsCallback(CFNotificationCenterRef center,
                                       void *observer,
                                       CFStringRef name,
                                       const void *object,
                                       CFDictionaryRef userInfo){
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    restoreAllMonitors();
}

// Explicit nice-only retry. One bounded event debounce; never a polling loop,
// and never calls the CPU policy execution path.
static BOOL nice_refresh_scheduled;
static void niceRefreshCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo){
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(vedette_serial_queue(), ^{
        if (nice_refresh_scheduled) return;
        nice_refresh_scheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), vedette_serial_queue(), ^{
            NSDictionary *prefs = getPrefs();
            vdt_nice_reload(prefs);
            vdt_nice_reconcile();
            for (NSDictionary *target in vdt_resolve_targets(vdt_configs_from_prefs(prefs)))
                vdt_nice_apply(target);
            vdt_nice_publish();
            nice_refresh_scheduled = NO;
        });
    });
}

static NSString *current_executable_path(pid_t pid){
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (!VDTCopyProcessInfoString(pid, path, sizeof(path), proc_pidpath)) return nil;
    return [NSString stringWithUTF8String:path];
}

%ctor{
    @autoreleasepool {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            pid_t pid = getpid();
            NSString *executablePath = current_executable_path(pid);
            BOOL isRunningBoard = [executablePath isEqualToString:@"/usr/libexec/runningboardd"];

            if (isRunningBoard) {
                reloadPrefs();
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, niceRefreshCallback, CFSTR(VDT_NICE_RETRY_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, niceRefreshCallback, CFSTR(VDT_NICE_RESTORE_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                notify_register_dispatch(NOTIFY_PID_NN,
                                         &notify_pid_token,
                                         dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                                         ^(int token) {
                    uint64_t reportedPid = 0;
                    uint32_t stateStatus = notify_get_state(token, &reportedPid);
                    dispatch_async(vedette_serial_queue(), ^{
                        // One fast path plus the trailing scan is enough for a
                        // notification burst. Bound public Darwin-name floods
                        // to one reconciliation cycle per debounce window.
                        if (launch_catch_up_scheduled) return;
                        if (stateStatus == NOTIFY_STATUS_OK && reportedPid > 0 && reportedPid <= INT_MAX) {
                            handle_reported_pid_sync((pid_t)reportedPid);
                        } else {
                            schedule_launch_catch_up_sync();
                        }
                    });
                });
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChangedCallback, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, restoreAllMonitorsCallback, (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                return;
            }

            // Every other injected process self-reports. runningboardd owns the
            // trusted prefs snapshot and decides whether this PID is configured.
            if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.Preferences"]) {
                return;
            }
            HBLogDebug(@"Notify new pid: %d", pid);
            notify_new_pid(NOTIFY_PID_NN, (uint64_t)pid);
        });
    }
}
