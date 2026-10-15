// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSListController.h>

PSSpecifier *VDTCheckResultSpecifier(NSDictionary *model);
UIColor *VDTCheckStateColor(NSString *tone);
@interface VDTCheckResultCell : PSTableCell
@end
