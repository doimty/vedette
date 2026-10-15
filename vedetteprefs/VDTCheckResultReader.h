// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import "VDTCheckResultModel.h"
// Immutable UI identity: identifier, numeric type, optional verified host.
// Reads existing preference/status files only. No notification or kernel request.
NSArray<NSDictionary *> *VDTReadCheckResultModels(NSDictionary *context, BOOL nicePending,
    VDTCheckLocalizer localize);
