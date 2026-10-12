// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
@interface VDTExtensionListController : PSListController <UISearchResultsUpdating>
- (void)reloadExtensionRule:(NSString *)identifier;
@end
