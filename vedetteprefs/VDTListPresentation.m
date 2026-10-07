// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: MIT

#import "VDTListPresentation.h"
#import "VDTListOrder.h"
#import "VDTLocalization.h"

BOOL VDTListConfigurationEnabled(NSString *identifier, VDTConfigType type, NSDictionary *prefs) {
    id value = valueForProcessConfigKeyWithPrefs(identifier, @"enabled", nil, type, prefs);
    // boolValue is not supported by arrays, dictionaries or NSNull. Keep the
    // existing NSNumber/NSString boolValue semantics for valid stored switches.
    return ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]])
        ? [value boolValue] : NO;
}

static int VDTCompareListNames(size_t left, size_t right, void *context) {
    NSArray<PSSpecifier *> *rows = (__bridge NSArray *)context;
    NSString *leftName = rows[left].name ?: @"";
    NSString *rightName = rows[right].name ?: @"";
    return (int)[leftName localizedCaseInsensitiveCompare:rightName];
}

NSMutableArray<PSSpecifier *> *VDTGroupedListSpecifiers(
    NSArray<PSSpecifier *> *source, NSString *identityKey, VDTConfigType type,
    Class localizationClass, BOOL (^matchesSearch)(PSSpecifier *), NSString *emptyTextKey) {
    NSMutableArray<PSSpecifier *> *rows = [NSMutableArray new];
    for (PSSpecifier *specifier in source) {
        if (specifier.cellType == PSGroupCell) continue;
        id identifier = [specifier propertyForKey:identityKey];
        if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0) continue;
        [rows addObject:specifier];
    }

    // One disk snapshot per rebuild, so sorting cannot mix old/new settings.
    NSDictionary *prefs = getPrefs();
    NSMutableData *itemsData = [NSMutableData dataWithLength:rows.count * sizeof(VDTListOrderItem)];
    NSMutableData *orderData = [NSMutableData dataWithLength:rows.count * sizeof(size_t)];
    VDTListOrderItem *items = itemsData.mutableBytes;
    size_t *order = orderData.mutableBytes;
    for (NSUInteger index = 0; index < rows.count; ++index) {
        PSSpecifier *specifier = rows[index];
        NSString *identifier = [specifier propertyForKey:identityKey];
        items[index] = (VDTListOrderItem){identifier.UTF8String,
            VDTListConfigurationEnabled(identifier, type, prefs),
            matchesSearch ? matchesSearch(specifier) : YES};
    }
    size_t enabledCount = 0;
    size_t count = VDTListBuildOrder(items, rows.count, order, &enabledCount,
                                    VDTCompareListNames, (__bridge void *)rows);
    NSMutableArray<PSSpecifier *> *result = [NSMutableArray new];
    for (size_t index = 0; index < count; ++index) {
        if (index == 0 || index == enabledCount) {
            PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
            group.name = VDTLoc(localizationClass, index < enabledCount ? @"Enabled Configurations" : @"Other");
            if (index == 0) {
                [group setProperty:VDTLoc(localizationClass,
                    @"Grouping reflects saved per-process switches, not live monitoring status.") forKey:@"footerText"];
            }
            [result addObject:group];
        }
        [result addObject:rows[order[index]]];
    }
    if (count == 0) {
        PSSpecifier *emptyGroup = [PSSpecifier emptyGroupSpecifier];
        [emptyGroup setProperty:VDTLoc(localizationClass, emptyTextKey) forKey:@"footerText"];
        [result addObject:emptyGroup];
    }
    return result;
}
