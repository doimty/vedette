#import <Foundation/Foundation.h>
#import <Preferences/PSSpecifier.h>
#import "../VDTShared.h"

@class VDTProcessConfiguration;
@class VDTNiceValueListController;

@interface VDTNicePreferences : NSObject
- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner;
- (NSArray<PSSpecifier *> *)specifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)requestRetry;
@end
