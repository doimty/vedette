// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Preferences/PSListController.h>
// Read-only saved fields for the presenting link's vdtCheckIndex and identity
// (vdtCheckContext: identifier, numeric type, optional verified host).
@interface VDTCheckDetailsController : PSListController
@end
@interface VDTCheckDiagnosticsController : VDTCheckDetailsController
@end
