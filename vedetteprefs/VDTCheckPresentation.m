// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckPresentation.h"

static void VDTAppendSection(NSMutableArray *sections, NSString *identifier, NSArray *fields) {
    if (fields.count) [sections addObject:@{@"id": identifier, @"fields": [fields copy]}];
}

NSArray<NSDictionary *> *VDTCheckPresentationSections(NSDictionary *model, BOOL diagnostics) {
    id rawCore = [model isKindOfClass:NSDictionary.class] ? model[@"coreFields"] : nil;
    id rawDetails = [model isKindOfClass:NSDictionary.class] ? model[@"diagnosticFields"] : nil;
    NSArray *core = [rawCore isKindOfClass:NSArray.class] ? rawCore : @[];
    NSArray *details = [rawDetails isKindOfClass:NSArray.class] ? rawDetails : @[];
    NSSet *resultIDs = [NSSet setWithArray:@[@"state", @"target", @"observed"]];
    NSSet *historyIDs = [NSSet setWithArray:@[@"lastAttempt"]];
    NSSet *identityIDs = [NSSet setWithArray:@[@"code", @"evidence", @"pid", @"instance", @"original", @"count"]];
    NSSet *executionIDs = [NSSet setWithArray:@[@"planSkip", @"executionSkip", @"outcome", @"executor", @"errno",
        @"storeError", @"checkedTarget", @"action", @"rawReadback", @"readStart", @"writeCalls"]];
    NSMutableArray *result = [NSMutableArray array], *check = [NSMutableArray array], *history = [NSMutableArray array];
    NSMutableArray *identity = [NSMutableArray array], *execution = [NSMutableArray array], *coverage = [NSMutableArray array];
    for (id raw in core) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *field = raw;
        NSString *identifier = [field[@"id"] isKindOfClass:NSString.class] ? field[@"id"] : @"";
        if ([historyIDs containsObject:identifier]) {
            if (diagnostics) [history addObject:field];
        } else if (!diagnostics) {
            [([resultIDs containsObject:identifier] ? result : check) addObject:field];
        }
    }
    if (diagnostics) {
        for (id raw in details) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *field = raw;
            NSString *identifier = [field[@"id"] isKindOfClass:NSString.class] ? field[@"id"] : @"";
            NSMutableArray *destination = [identityIDs containsObject:identifier] ? identity :
                [executionIDs containsObject:identifier] ? execution : coverage;
            [destination addObject:field];
        }
    }
    NSMutableArray *sections = [NSMutableArray array];
    if (diagnostics) {
        VDTAppendSection(sections, @"history", history);
        VDTAppendSection(sections, @"identity", identity);
        VDTAppendSection(sections, @"execution", execution);
        VDTAppendSection(sections, @"coverage", coverage);
    } else {
        VDTAppendSection(sections, @"result", result);
        VDTAppendSection(sections, @"check", check);
    }
    return [sections copy];
}

NSArray<NSDictionary *> *VDTCheckPresentationFields(NSDictionary *model, BOOL diagnostics) {
    NSMutableArray *fields = [NSMutableArray array];
    for (NSDictionary *section in VDTCheckPresentationSections(model, diagnostics))
        [fields addObjectsFromArray:section[@"fields"]];
    return [fields copy];
}
