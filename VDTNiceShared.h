// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import "VDTShared.h"

#define VDT_NICE_ENABLED_KEY @"niceEnabled"
#define VDT_NICE_VALUE_KEY @"niceValue"
#define VDT_NICE_REVISION_KEY @"niceRevision"
#define VDT_NICE_RESULTS_NOTIFICATION "com.doimty.vedette.nice-results"
#define VDT_NICE_RETRY_NOTIFICATION "com.doimty.vedette.nice-retry"
#define VDT_NICE_RESTORE_NOTIFICATION "com.doimty.vedette.nice-restore"

enum { VDTNiceMinimum = -20, VDTNiceMaximum = 20, VDTNiceMaximumRecords = 1024 };

#ifdef __cplusplus
extern "C" {
#endif
// Only true integer NSNumber or a complete base-10 integer string is accepted.
// Booleans, fractional/overflow/missing values are rejected.
BOOL VDTNiceParseValue(id value, int *result);
NSString *VDTNiceRuleKey(VDTConfigType type, NSString *identifier);
NSString *VDTNiceStateDirectory(void);
NSString *VDTNiceBootToken(void);
// First-entry-wins. Each rule contains type/identifier/value/valid/revision,
// requestedEnabled (per-rule), enabled (folds global switch). CPU keys are not read.
NSDictionary<NSString *, NSDictionary *> *VDTNiceRulesFromPrefs(NSDictionary *prefs);
// Separate checked atomic writer; preserves all legacy CPU keys. Only niceEnabled
// or niceValue may be changed. Enabling an untouched rule atomically stores value 0.
BOOL VDTNiceSavePreference(NSString *identifier, VDTConfigType type,
                           NSString *key, id value, NSError **error);
// Last execution receipt, not a live kernel query. Returns nil if boot, revision,
// enabled/valid/value differ from CURRENT prefs, or the receipt is unavailable.
// A receipt row contains state (stable ASCII code), error, checkedAt, targetCount,
// appliedCount, pendingCount; observed/original may be present for a single target.
NSDictionary *VDTNiceMatchingStatus(NSString *identifier, VDTConfigType type,
                                    NSDictionary *prefs);
#ifdef __cplusplus
}
#endif
