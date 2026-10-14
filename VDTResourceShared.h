// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import "VDTShared.h"
#ifdef __cplusplus
extern "C" {
#endif
#define VDT_RESOURCE_STATUS_NN "com.doimty.vedette.resource-status"
#define VDT_RESOURCE_RESTORE_NN "com.doimty.vedette.resource-removal"
NSString *VDTResourceStateDirectory(void);
BOOL VDTResourceWriteEnabled(NSDictionary *prefs);
NSDictionary *VDTResourceConfiguration(NSDictionary *prefs);
BOOL VDTResourceSavePriority(NSString *identifier, VDTConfigType type, NSNumber *value);
BOOL VDTResourceFollowApp(NSString *identifier, NSString *section);
NSDictionary *VDTResourceMatchingStatus(NSString *identifier, VDTConfigType type, NSDictionary *prefs);
#ifdef __cplusplus
}
#endif
