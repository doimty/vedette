//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTApplicationListSubcontrollerController.h"
#import "../VDTShared.h"
#import "VDTLocalization.h"

@implementation VDTApplicationListSubcontrollerController
- (NSString*)previewStringForApplicationWithIdentifier:(NSString *)applicationID{
    return [valueForProcessConfigKey(applicationID, @"enabled", nil, VDTConfigTypeApp) boolValue] ? VDTLoc([self class], @"Enabled") : @"";
}
@end
