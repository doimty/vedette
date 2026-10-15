// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultsPreferences.h"
#import "VDTCheckResultModel.h"
#import "VDTCheckResultCell.h"
#import "VDTCheckResultReader.h"
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
- (NSDictionary *)checkContext {
    NSString *identifier = [_owner vdtNiceIdentifier];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return @{};
    VDTConfigType type = [_owner vdtNiceConfigurationType];
    NSString *host = type == VDTConfigTypeExtension ? [self verifiedHostForIdentifier:identifier] : nil;
    NSMutableDictionary *context = [@{@"identifier": identifier, @"type": @(type),
        @"nicePending": @(_nicePending)} mutableCopy];
    if (host) context[@"host"] = host;
    return [context copy];
}
- (void)reloadModels {
    if (!_owner || !_resultRows.count) return;
    NSDictionary *context = [self checkContext];
    NSArray *models = VDTReadCheckResultModels(context, _nicePending,
        ^NSString *(NSString *key) { return VDTLoc(self.class, key); });
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
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Last apply result")
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [rows addObject:group];
        NSMutableArray *results = [NSMutableArray array];
        for (NSUInteger index = 0; index < 3; index++) {
            PSSpecifier *result = VDTCheckResultSpecifier(@{});
            [results addObject:result]; [rows addObject:result];
        }
        _resultRows = [results copy];
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
