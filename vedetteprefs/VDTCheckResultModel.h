// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef NSString *(^VDTCheckLocalizer)(NSString *key);
// Pure historical display projection. Each row has title/state/tone/summary,
// timestamp and scope, plus stable coreFields/diagnosticFields arrays. Fields
// have id/label/value/tone. No current-observation fallback or file/kernel IO.
NSArray<NSDictionary *> *VDTCheckResultModels(NSDictionary *niceRule, NSDictionary *niceReceipt,
    NSDictionary *memoryRule, NSDictionary *jetsamRule, NSDictionary *resourceReceipt,
    VDTCheckLocalizer localize);
#ifdef __cplusplus
}
#endif
