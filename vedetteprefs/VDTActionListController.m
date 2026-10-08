#import "VDTActionListController.h"
#import "VDTProcessConfiguration.h"

@implementation VDTActionListController

- (VDTProcessConfiguration *)ownerConfiguration {
    PSViewController *parent = self.parentController;
    return [parent isKindOfClass:VDTProcessConfiguration.class]
        ? (VDTProcessConfiguration *)parent : nil;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    VDTProcessConfiguration *owner = [self ownerConfiguration];
    return owner ? [owner readProcessConfigValue:specifier] : [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    VDTProcessConfiguration *owner = [self ownerConfiguration];
    if (owner) {
        [owner setProcessConfigValue:value specifier:specifier];
        [owner reloadSpecifier:specifier animated:NO];
    }
}

@end
