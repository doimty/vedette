// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: MIT

#import <Preferences/PSSpecifier.h>
#import "../VDTShared.h"

#ifdef __cplusplus
extern "C" {
#endif

// Same snapshot for CPU || nice || memory || jetsam. Nice/resource switches
// require CFBoolean; CPU retains legacy NSNumber/NSString boolValue semantics.
// Never consults the global switch, inherited rules, or runtime receipts.
BOOL VDTListConfigurationEnabled(NSString *identifier, VDTConfigType type, NSDictionary *prefs);
// Localization key only; distinguishes CPU inheritance from independent rules.
NSString *VDTListExtensionSubtitleKey(NSString *identifier, NSDictionary *prefs);

// Does not modify the source array (in particular AltList's _allSpecifiers cache).
// A nil predicate means the source has already been filtered by AltList.
NSMutableArray<PSSpecifier *> *VDTGroupedListSpecifiers(
    NSArray<PSSpecifier *> *source, NSString *identityKey, VDTConfigType type,
    Class localizationClass, BOOL (^matchesSearch)(PSSpecifier *), NSString *emptyTextKey);

#ifdef __cplusplus
}
#endif
