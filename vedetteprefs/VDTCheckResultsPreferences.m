// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultsPreferences.h"
#import "VDTCheckResultModel.h"
#import "VDTCheckResultCell.h"
#import "VDTProcessConfiguration.h"
#import "VDTNicePreferences.h"
#import "VDTLocalization.h"
#import "../VDTNiceShared.h"
#import "../VDTResourceShared.h"
#include <notify.h>

@interface VDTCheckResultsPreferences () {
    __weak VDTProcessConfiguration *_owner;
    NSArray<PSSpecifier *> *_specifiers;
    NSArray<PSSpecifier *> *_resultRows;
    PSSpecifier *_details;
    BOOL _buildingSpecifiers, _nicePending, _refreshScheduled;
    int _resourceToken;
    BOOL _resourceObserverRegistered;
}
@end
@implementation VDTCheckResultsPreferences
- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner {
    self = [super init];
    if (!self) return nil;
    _owner = owner; _resourceToken = -1;
    __weak VDTCheckResultsPreferences *weakSelf = self;
    int result = notify_register_dispatch(VDT_RESOURCE_STATUS_NN, &_resourceToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        VDTCheckResultsPreferences *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_refreshScheduled) return;
        strongSelf->_refreshScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            VDTCheckResultsPreferences *pending = weakSelf;
            if (!pending) return;
            pending->_refreshScheduled = NO;
            [pending reloadModels]; // status file only; never requests a kernel check
        });
    });
    _resourceObserverRegistered = result == NOTIFY_STATUS_OK;
    return self;
}
- (void)dealloc {
    if (_resourceObserverRegistered && _resourceToken >= 0) notify_cancel(_resourceToken);
}
- (NSString *)verifiedHostForIdentifier:(NSString *)identifier {
    id metadata = [_owner.specifier propertyForKey:@"vdtExtensionMetadata"];
    if (![metadata isKindOfClass:NSDictionary.class] || ![metadata[@"extensionIdentifier"] isEqual:identifier]) return nil;
    id host = metadata[@"containingAppIdentifier"];
    return [host isKindOfClass:NSString.class] && [host length] ? host : nil;
}
- (NSDictionary *)resourceRule:(NSString *)section identifier:(NSString *)identifier type:(VDTConfigType)type
    host:(NSString *)host prefs:(NSDictionary *)prefs {
    // Match execution's presence-first extension inheritance. An own disabled
    // or invalid record still blocks its host; use only cached verified metadata.
    NSString *source = identifier; VDTConfigType sourceType = type;
    if (!VDTHasProcessResourceRule(source, sourceType, section, prefs)) {
        if (type != VDTConfigTypeExtension || !host || !VDTHasProcessResourceRule(host, VDTConfigTypeApp, section, prefs)) return nil;
        source = host; sourceType = VDTConfigTypeApp;
    }
    NSMutableDictionary *rule = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"enabled", @"schema", @"active", @"inactive", @"priority", @"sourceDarwinMajor"]) {
        id value = valueForProcessResourceRuleKeyWithPrefs(source, key, nil, sourceType, section, prefs);
        if (value) rule[key] = value;
    }
    return rule;
}
- (void)reloadModels {
    if (!_owner || !_resultRows.count) return;
    NSDictionary *prefs = getPrefs();
    if (![prefs isKindOfClass:NSDictionary.class]) prefs = @{};
    NSString *identifier = [_owner vdtNiceIdentifier];
    VDTConfigType type = [_owner vdtNiceConfigurationType];
    NSString *host = type == VDTConfigTypeExtension ? [self verifiedHostForIdentifier:identifier] : nil;
    NSDictionary *niceRule = VDTNiceEffectiveRule(identifier, type, host, prefs);
    NSDictionary *niceReceipt = _nicePending ? nil : VDTNiceMatchingStatusWithHost(identifier, type, host, prefs);
    NSDictionary *resourceReceipt = VDTResourceMatchingStatus(identifier, type, prefs);
    NSArray *models = VDTCheckResultModels(niceRule, niceReceipt,
        [self resourceRule:@"memoryRules" identifier:identifier type:type host:host prefs:prefs],
        [self resourceRule:@"jetsamRules" identifier:identifier type:type host:host prefs:prefs], resourceReceipt,
        ^NSString *(NSString *key) { return VDTLoc(self.class, key); });
    [_details setProperty:[models copy] forKey:@"vdtCheckModels"];
    for (NSUInteger index = 0; index < _resultRows.count; index++) {
        PSSpecifier *row = _resultRows[index];
        [row setProperty:models[index] forKey:@"vdtCheckModel"];
        // Keep the table's cached specifier objects alive. No naked _specifiers
        // reset or whole-table rebuild from a notification / transition callback.
        if (!_buildingSpecifiers && _owner.isViewLoaded) [_owner reloadSpecifier:row animated:NO];
    }
}
- (NSArray<PSSpecifier *> *)specifiers {
    _buildingSpecifiers = YES;
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Recent check results")
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:VDTLoc(self.class, @"Historical receipt, not live monitoring. Refresh only reloads saved results.") forKey:@"footerText"];
        [rows addObject:group];
        NSMutableArray *results = [NSMutableArray array];
        for (NSUInteger index = 0; index < 3; index++) {
            PSSpecifier *result = VDTCheckResultSpecifier(@{}, NO);
            [results addObject:result]; [rows addObject:result];
        }
        _resultRows = [results copy];
        _details = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Check details")
            target:nil set:nil get:nil detail:VDTCheckDetailsController.class cell:PSLinkCell edit:nil];
        [rows addObject:_details];
        PSSpecifier *refresh = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Refresh display")
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [refresh setButtonAction:@selector(refreshDisplay)]; [rows addObject:refresh];
        [rows addObject:[PSSpecifier emptyGroupSpecifier]];
        PSSpecifier *retry = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Check / retry nice")
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [retry setButtonAction:@selector(requestNiceRetry)]; [rows addObject:retry];
        _specifiers = [rows copy];
    }
    [self reloadModels];
    _buildingSpecifiers = NO;
    return _specifiers;
}
- (void)refreshDisplay {
    // Explicitly reread historical files, not a request for live verification.
    _nicePending = NO;
    [self reloadModels];
}
- (void)markNicePending {
    _nicePending = YES;
    [self reloadModels];
}
- (void)niceResultDidChange {
    _nicePending = NO;
    [self reloadModels];
}
- (void)requestNiceRetry {
    [[_owner vdtNicePreferences] requestRetry]; // the existing nice-only notification
}
@end
