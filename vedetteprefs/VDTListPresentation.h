// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: MIT

#import <Preferences/PSSpecifier.h>
#import "../VDTShared.h"

// Invalid/missing values are off. Uses the same first matching configuration and
// original identity keys as the detail controller. Never consults the main switch.
BOOL VDTListConfigurationEnabled(NSString *identifier, VDTConfigType type, NSDictionary *prefs);

// Does not modify the source array (in particular AltList's _allSpecifiers cache).
// A nil predicate means the source has already been filtered by AltList.
NSMutableArray<PSSpecifier *> *VDTGroupedListSpecifiers(
    NSArray<PSSpecifier *> *source, NSString *identityKey, VDTConfigType type,
    Class localizationClass, BOOL (^matchesSearch)(PSSpecifier *), NSString *emptyTextKey);
