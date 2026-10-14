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
void vdt_resource_reconcile(NSArray<NSDictionary *> *targets);
void vdt_resource_publish(void);
NSTimeInterval vdt_resource_next_retry_delay(void);
BOOL vdt_resource_restore_all(void);
#ifdef __cplusplus
}
#endif
