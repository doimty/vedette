// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#import <Preferences/PSSpecifier.h>
@class VDTProcessConfiguration;
@interface VDTCheckResultsPreferences : NSObject
- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner;
- (NSArray<PSSpecifier *> *)specifiers;
- (void)refreshDisplay;
- (void)markNicePending;
- (void)niceResultDidChange;
@end
