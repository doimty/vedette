//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"

#include <notify.h>
#include <os/lock.h>

#pragma mark - Serial queue for prefs/monitoring work
// Startup, config changes, process reconciliation, and CPU syscalls share one queue.

static dispatch_queue_t vedette_serial_queue(void){
    static dispatch_once_t once;
    static dispatch_queue_t queue;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.udevs.vedette.serial", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

#pragma mark - Process table change events

static int process_table_changed_token;
static os_unfair_lock process_reconcile_lock = OS_UNFAIR_LOCK_INIT;
static BOOL process_reconcile_pending = NO;

// Darwin notifications are coalescible; the event is only a hint to rescan live processes.
static void notify_process_table_changed(void){
    notify_post(PROCESS_TABLE_CHANGED_NN);
}

static void schedule_process_reconciliation(void){
    os_unfair_lock_lock(&process_reconcile_lock);
    if (process_reconcile_pending){
        os_unfair_lock_unlock(&process_reconcile_lock);
        return;
    }
    process_reconcile_pending = YES;
    os_unfair_lock_unlock(&process_reconcile_lock);

    dispatch_async(vedette_serial_queue(), ^{
        os_unfair_lock_lock(&process_reconcile_lock);
        process_reconcile_pending = NO;
        os_unfair_lock_unlock(&process_reconcile_lock);
        VDTReconcileProcessRules(VDTGetPrefs(), NO);
    });
}

#pragma mark - Runningboardd rule reconciliation

static void reloadPrefsSync(void){
    NSDictionary *newPrefs = getPrefs();
    VDTSetPrefs(newPrefs);
    VDTReconcileProcessRules(newPrefs, YES);
}

// Safe to call from any context; the immutable preference snapshot is rebuilt on the serial queue.
static void reloadPrefs(void){
    dispatch_async(vedette_serial_queue(), ^{
        reloadPrefsSync();
    });
}

static void restoreAllMonitors(void){
    dispatch_async(vedette_serial_queue(), ^{
        NSDictionary *temporaryPrefs = getTempPrefs();
        VDTRestoreProcessesMatchingPrefs(temporaryPrefs);
        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];
    });
}

%ctor{
    @autoreleasepool {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSProcessInfo *procInfo = [objc_getClass("NSProcessInfo") processInfo];
            NSArray *args = [procInfo arguments];
            if (!args.count) return;

            NSString *executablePath = args[0];
            if (!executablePath.length) return;

            BOOL isApplication = ([executablePath rangeOfString:@"/Application"].location != NSNotFound)
                || ([executablePath rangeOfString:@"/CoreServices"].location != NSNotFound);
            NSString *processName = executablePath.lastPathComponent;

            if ([processName isEqualToString:@"runningboardd"]){
                // Register first so process starts during the initial scan cause a follow-up scan.
                notify_register_dispatch(PROCESS_TABLE_CHANGED_NN, &process_table_changed_token,
                                         dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                                         ^(__unused int token) {
                    schedule_process_reconciliation();
                });
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                                (CFNotificationCallback)reloadPrefs,
                                                (CFStringRef)PREFS_CHANGED_NN, NULL,
                                                CFNotificationSuspensionBehaviorDeliverImmediately);
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                                (CFNotificationCallback)restoreAllMonitors,
                                                (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL,
                                                CFNotificationSuspensionBehaviorDeliverImmediately);
                reloadPrefs();
                return;
            }

            if (isApplication
                && [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.Preferences"]){
                return;
            }
            notify_process_table_changed();
        });
    }
}
