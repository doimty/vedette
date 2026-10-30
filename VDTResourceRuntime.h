// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import "VDTProcessManager.h"
#import "VDTResourceApply.h"
#ifdef __cplusplus
extern "C" {
#endif
// Confined to the existing runningboardd serial queue. No resident timer/scan.
void vdt_resource_reload(NSDictionary *prefs);
BOOL vdt_resource_apply(NSDictionary *target, const VDTMemoryRule *memory, const VDTJetsamRule *jetsam);
// Starts a display-only check batch. Enumeration success is not proof that all
// process metadata resolved, and neither this flag nor absence authorizes restore.
void vdt_resource_begin_check(NSArray<NSDictionary *> *targets, BOOL enumerationComplete, int scanError);
void vdt_resource_reconcile(NSArray<NSDictionary *> *targets);
void vdt_resource_publish(void);
NSTimeInterval vdt_resource_next_retry_delay(void);
BOOL vdt_resource_restore_all(void);
#ifdef __cplusplus
}
#endif
