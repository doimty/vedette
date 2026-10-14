//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "../Common.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "PrivateHeaders.h"
#import "../VDTShared.h"

@class VDTNicePreferences, VDTCheckResultsPreferences;

@interface VDTProcessConfiguration : PSListController{
    PSSpecifier *_intervalSpecifier;
    PSSpecifier *_enabledSpecifier;
    VDTNicePreferences *_nicePreferences;
    VDTCheckResultsPreferences *_checkResults;
}
- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readProcessConfigValue:(PSSpecifier *)specifier;
- (NSString *)vdtNiceIdentifier;
- (VDTConfigType)vdtNiceConfigurationType;
- (VDTNicePreferences *)vdtNicePreferences;
- (void)vdtReloadIndependentRules;
- (NSArray *)vdtCheckResultSpecifiers;
- (void)vdtMarkNiceCheckPending;
- (void)vdtNiceCheckDidRefresh;
- (void)vdtRefreshCheckResults;
- (void)vdtFollowMemoryApp;
- (void)vdtFollowJetsamApp;
- (void)vdtFollowResourceSection:(NSString *)section;
- (void)presentResourceRuleError:(NSString *)title message:(NSString *)message;
@end
