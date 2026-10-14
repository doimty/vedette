// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef NSString *(^VDTCheckLocalizer)(NSString *key);
// Pure display projection. Inputs are already selected rules / matching historical
// receipts, never live observations. Each of the three rows has string fields
// title, state, tone, summary, timestamp and details. No file, preference or kernel IO.
NSArray<NSDictionary *> *VDTCheckResultModels(NSDictionary *niceRule, NSDictionary *niceReceipt,
    NSDictionary *memoryRule, NSDictionary *jetsamRule, NSDictionary *resourceReceipt,
    VDTCheckLocalizer localize);
#ifdef __cplusplus
}
#endif
