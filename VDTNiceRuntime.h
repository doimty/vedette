// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import "VDTProcessManager.h"
#ifdef __cplusplus
extern "C" {
#endif
// All entry points are confined to the existing runningboardd serial queue.
void vdt_nice_reload(NSDictionary *prefs);
void vdt_nice_reconcile(void);
void vdt_nice_apply(NSDictionary *target);
void vdt_nice_publish(void);
// -1 means settled; otherwise a monotonic delay for one coalesced retry task.
NSTimeInterval vdt_nice_next_retry_delay(void);
BOOL vdt_nice_restore_all(void);
#ifdef __cplusplus
}
#endif
