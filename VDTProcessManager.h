//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>

#ifdef __cplusplus
extern "C" {
#endif

// Thread-safe prefs accessors. Use instead of direct global access.
void VDTSetPrefs(NSDictionary *newPrefs);
NSDictionary *VDTGetPrefs(void);

void monitor_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals);
void throttle_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages);
// Must be called on the serialized process-management queue.
void VDTReconcileProcessRules(NSDictionary *prefs, BOOL force);
void VDTRestoreProcessesMatchingPrefs(NSDictionary *prefs);
//void restore_all_monitors();

#ifdef __cplusplus
}
#endif

