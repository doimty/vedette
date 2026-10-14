// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#import "VDTResourceApply.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { __unsafe_unretained NSDictionary *target; } VDTResourceSystemContext;
VDTApplyCapabilities VDTResourceSystemCapabilities(void);
const VDTResourceBackend *VDTResourceSystemBackend(void);
#ifdef __cplusplus
}
#endif
