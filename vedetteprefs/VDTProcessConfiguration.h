//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "../Common.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "PrivateHeaders.h"
#import "../VDTShared.h"

@class VDTNicePreferences;

@interface VDTProcessConfiguration : PSListController{
    PSSpecifier *_intervalSpecifier;
    PSSpecifier *_enabledSpecifier;
    VDTNicePreferences *_nicePreferences;
}
- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readProcessConfigValue:(PSSpecifier *)specifier;
- (NSString *)vdtNiceIdentifier;
- (VDTConfigType)vdtNiceConfigurationType;
- (VDTNicePreferences *)vdtNicePreferences;
@end
