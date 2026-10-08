#import "VDTNiceValueListController.h"
#import "VDTProcessConfiguration.h"
#import "VDTNicePreferences.h"

@implementation VDTNiceValueListController

- (VDTNicePreferences *)nicePreferencesOwner {
    PSViewController *controller = self.parentController;
    while (controller && ![controller isKindOfClass:[VDTProcessConfiguration class]])
        controller = controller.parentController;
    return [controller isKindOfClass:[VDTProcessConfiguration class]]
        ? [(VDTProcessConfiguration *)controller vdtNicePreferences] : nil;
}

// PSListItemsController installs itself as the selection target for link-list
// specifiers. Route the selection back through the retained detail helper.
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    VDTNicePreferences *owner = [self nicePreferencesOwner];
    return owner ? [owner readPreferenceValue:specifier] : [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    VDTNicePreferences *owner = [self nicePreferencesOwner];
    if (owner) {
        [owner setPreferenceValue:value specifier:specifier];
        // The helper refreshes the row on its original owner after a checked save.
    }
}

@end
