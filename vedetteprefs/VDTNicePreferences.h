#import <Foundation/Foundation.h>
#import <Preferences/PSSpecifier.h>
#import "../VDTShared.h"

@class VDTProcessConfiguration;
@class VDTNiceValueListController;

// Reads only this snapshot and cached verified list metadata; never scans bundles.
id VDTNicePreferenceValueWithPrefs(NSString *identifier, VDTConfigType type, NSString *key,
    id fallback, NSDictionary *prefs, NSDictionary *extensionMetadata);

@interface VDTNicePreferences : NSObject
- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner;
- (NSArray<PSSpecifier *> *)specifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)requestRetry;
@end
