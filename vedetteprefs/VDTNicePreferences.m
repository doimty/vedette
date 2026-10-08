#import "VDTNicePreferences.h"
#import "../VDTNiceShared.h"
#import "VDTProcessConfiguration.h"
#import "VDTNiceValueListController.h"
#import "VDTLocalization.h"
#import "../Common.h"
#import <notify.h>
#import <CoreFoundation/CoreFoundation.h>

@interface VDTNicePreferences () {
    __weak VDTProcessConfiguration *_owner;
    NSMutableArray<PSSpecifier *> *_specifiers;
    PSSpecifier *_statusSpecifier;
    PSSpecifier *_enabledSpecifier;
    NSString *_statusText;
    int _notifyToken;
    BOOL _observerRegistered;
    BOOL _buildingSpecifiers;
}
@end

@implementation VDTNicePreferences

- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner {
    self = [super init];
    if (self) {
        _owner = owner;
        _notifyToken = -1;
        _statusText = VDTLoc(self.class, @"Waiting for execution result");
        __weak VDTNicePreferences *weakSelf = self;
        int status = notify_register_dispatch(VDT_NICE_RESULTS_NOTIFICATION, &_notifyToken,
            dispatch_get_main_queue(), ^(int token) {
                VDTNicePreferences *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setPendingStatusAndReload];
                __weak VDTNicePreferences *deferredSelf = strongSelf;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [deferredSelf refreshMatchingStatus];
                });
            });
        _observerRegistered = (status == NOTIFY_STATUS_OK);
    }
    return self;
}

- (void)dealloc {
    if (_observerRegistered && _notifyToken >= 0) notify_cancel(_notifyToken);
}

- (VDTConfigType)configurationType {
    return (VDTConfigType)[_owner vdtNiceConfigurationType];
}

- (NSString *)identifier {
    return [_owner vdtNiceIdentifier] ?: @"";
}

- (BOOL)isProtectedTarget {
    NSString *identifier = self.identifier.lowercaseString;
    if (self.configurationType == VDTConfigTypeApp)
        return [identifier isEqualToString:@"com.apple.preferences"];
    return [@[@"launchd", @"com.apple.launchd", @"runningboardd", @"com.apple.runningboardd"] containsObject:identifier];
}

- (BOOL)isSensitiveTarget {
    NSString *identifier = self.identifier.lowercaseString;
    return [@[@"springboard", @"sb", @"com.apple.springboard", @"backboardd",
        @"com.apple.backboardd", @"xpcproxy", @"com.apple.xpcproxy", @"sshd"] containsObject:identifier];
}

- (BOOL)isEnabledValue:(id)value {
    return [value isKindOfClass:[NSNumber class]]
        && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((__bridge CFBooleanRef)value);
}

- (BOOL)storedNiceEnabled {
    id value = valueForProcessConfigKey(self.identifier, VDT_NICE_ENABLED_KEY, @NO, self.configurationType);
    return [self isEnabledValue:value];
}

- (void)updateProtectedSwitchAvailability {
    if (!_enabledSpecifier) return;
    [_enabledSpecifier setProperty:@(![self isProtectedTarget] || [self storedNiceEnabled]) forKey:@"enabled"];
}

- (NSArray<PSSpecifier *> *)specifiers {
    if (!_specifiers) {
        _specifiers = [NSMutableArray array];
        _buildingSpecifiers = YES;
        PSSpecifier *niceGroup = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Scheduling priority (nice)")
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        NSString *footer = [self isProtectedTarget]
            ? VDTLoc(self.class, @"Nice cannot be enabled for this protected process. The value can still be saved.")
            : VDTLoc(self.class, @"Nice is independent of CPU limits. Turning this switch off restores the captured original value, not necessarily 0. Lower values have higher priority.");
        [niceGroup setProperty:footer forKey:@"footerText"];
        [_specifiers addObject:niceGroup];

        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Enable nice adjustment")
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [enabled setProperty:VDTLoc(self.class, @"Enable nice adjustment") forKey:@"label"];
        [enabled setProperty:VDT_NICE_ENABLED_KEY forKey:@"key"];
        [enabled setProperty:@NO forKey:@"default"];
        [enabled setProperty:@(![self isProtectedTarget]) forKey:@"enabled"];
        _enabledSpecifier = enabled;
        [self updateProtectedSwitchAvailability];
        [_specifiers addObject:enabled];

        PSSpecifier *value = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Nice value")
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:[VDTNiceValueListController class] cell:PSLinkListCell edit:nil];
        NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:41];
        NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:41];
        for (NSInteger nice = VDTNiceMinimum; nice <= VDTNiceMaximum; nice++) {
            [values addObject:@(nice)];
            [titles addObject:[NSString stringWithFormat:@"%ld", (long)nice]];
        }
        [value setValues:values titles:titles];
        [value setProperty:@0 forKey:@"default"];
        [value setProperty:VDT_NICE_VALUE_KEY forKey:@"key"];
        [value setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [_specifiers addObject:value];

        PSSpecifier *statusGroup = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Nice execution status")
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [statusGroup setProperty:_statusText forKey:@"footerText"];
        _statusSpecifier = statusGroup;
        [_specifiers addObject:statusGroup];

        PSSpecifier *retry = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Check / retry nice")
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [retry setButtonAction:@selector(requestRetry:)];
        [_specifiers addObject:retry];

        [self refreshMatchingStatus];
        _buildingSpecifiers = NO;
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id fallback = [specifier propertyForKey:@"default"];
    if (![key isEqualToString:VDT_NICE_ENABLED_KEY] && ![key isEqualToString:VDT_NICE_VALUE_KEY])
        return fallback;
    id value = valueForProcessConfigKey(self.identifier, key, fallback, self.configurationType);
    if ([key isEqualToString:VDT_NICE_ENABLED_KEY]) return @([self isEnabledValue:value]);
    int parsed = 0;
    return VDTNiceParseValue(value, &parsed) ? @(parsed) : @0;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isEqualToString:VDT_NICE_ENABLED_KEY] && ![key isEqualToString:VDT_NICE_VALUE_KEY]) return;
    BOOL enabling = [self isEnabledValue:value];
    if ([key isEqualToString:VDT_NICE_ENABLED_KEY] && enabling && [self isProtectedTarget]) {
        [_owner reloadSpecifier:specifier animated:YES];
        return;
    }
    if ([key isEqualToString:VDT_NICE_VALUE_KEY]) {
        int parsed = 0;
        if (!VDTNiceParseValue(value, &parsed)) {
            [self presentSaveError:nil];
            [_owner reloadSpecifier:specifier animated:YES];
            return;
        }
        value = @(parsed);
    }
    if ([key isEqualToString:VDT_NICE_ENABLED_KEY] && enabling && [self isSensitiveTarget]) {
        [self presentSensitiveProcessConfirmationForSpecifier:specifier value:value];
        return;
    }
    [self saveValue:value key:key specifier:specifier];
}

- (void)presentSensitiveProcessConfirmationForSpecifier:(PSSpecifier *)specifier value:(id)value {
    NSString *title = VDTLoc(self.class, @"Essential process — nice adjustment");
    NSString *message = [NSString stringWithFormat:VDTLoc(self.class,
        @"Changing the nice value of %@ may affect system responsiveness or stability. Continue?"), self.identifier];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"Cancel")
        style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            [self->_owner reloadSpecifier:specifier animated:YES];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"I Understand")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self saveValue:value key:VDT_NICE_ENABLED_KEY specifier:specifier];
        }]];
    [_owner presentViewController:alert animated:YES completion:nil];
}

- (void)saveValue:(id)value key:(NSString *)key specifier:(PSSpecifier *)specifier {
    NSError *error = nil;
    BOOL saved = VDTNiceSavePreference(self.identifier, self.configurationType, key, value, &error);
    if (!saved) {
        [self presentSaveError:error];
        [_owner reloadSpecifier:specifier animated:YES];
        return;
    }
    // A save is only a request. Do not turn this into an applied-success claim.
    [self setPendingStatusAndReload];
    [_owner reloadSpecifier:specifier animated:NO];
}

- (void)presentSaveError:(NSError *)error {
    NSString *reason = error.localizedDescription.length ? error.localizedDescription
        : VDTLoc(self.class, @"The preference could not be saved.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:VDTLoc(self.class, @"Nice save failed")
        message:reason preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [_owner presentViewController:alert animated:YES completion:nil];
}

- (void)requestRetry:(PSSpecifier *)specifier {
    [self requestRetry];
}

- (void)requestRetry {
    [self setPendingStatusAndReload];
    notify_post(VDT_NICE_RETRY_NOTIFICATION);
}

- (void)setPendingStatusAndReload {
    _statusText = VDTLoc(self.class, @"Waiting for execution result");
    if (_statusSpecifier) {
        [_statusSpecifier setProperty:_statusText forKey:@"footerText"];
        if (!_buildingSpecifiers) [_owner reloadSpecifier:_statusSpecifier animated:YES];
    }
}

- (NSString *)localizedState:(id)rawState {
    if (![rawState isKindOfClass:[NSString class]]) return VDTLoc(self.class, @"Nice state unavailable");
    NSDictionary<NSString *, NSString *> *keys = @{
        @"applied": @"Nice state applied", @"restored": @"Nice state restored",
        @"disabled": @"Nice state disabled", @"pending": @"Nice state pending",
        @"target-not-running": @"No verified running instance",
        @"identity-unavailable": @"Nice state identity unavailable",
        @"read-failed": @"Nice state read failed", @"write-failed": @"Nice state write failed",
        @"verify-failed": @"Nice state verify failed", @"store-failed": @"Nice state store failed",
        @"conflict": @"Nice state conflict", @"invalid": @"Nice state invalid",
        @"protected": @"Nice state protected", @"state-unavailable": @"Nice state unavailable",
        @"boot-unavailable": @"Nice state boot unavailable", @"paused": @"Nice state paused"
    };
    NSString *key = keys[rawState];
    return key ? VDTLoc(self.class, key) : VDTLoc(self.class, @"Nice state unavailable");
}

- (void)refreshMatchingStatus {
    if (!_owner) return;
    NSDictionary *receipt = VDTNiceMatchingStatus(self.identifier, self.configurationType, getPrefs());
    if (![receipt isKindOfClass:[NSDictionary class]]) {
        _statusText = VDTLoc(self.class, @"Waiting for execution result");
    } else {
        NSMutableArray<NSString *> *details = [NSMutableArray array];
        id original = receipt[@"original"];
        id current = receipt[@"observed"] ?: receipt[@"current"];
        id error = receipt[@"error"];
        id pending = receipt[@"pendingCount"];
        if ([original isKindOfClass:[NSNumber class]])
            [details addObject:[NSString stringWithFormat:VDTLoc(self.class, @"Original: %@"), original]];
        if ([current isKindOfClass:[NSNumber class]])
            [details addObject:[NSString stringWithFormat:VDTLoc(self.class, @"Read back: %@"), current]];
        if ([error isKindOfClass:[NSNumber class]])
            [details addObject:[NSString stringWithFormat:VDTLoc(self.class, @"errno: %@"), error]];
        if ([pending isKindOfClass:[NSNumber class]])
            [details addObject:[NSString stringWithFormat:VDTLoc(self.class, @"Pending targets: %@"), pending]];
        NSString *state = [self localizedState:receipt[@"state"]];
        NSString *base = [NSString stringWithFormat:VDTLoc(self.class, @"Latest receipt (not live): %@"), state];
        _statusText = details.count ? [NSString stringWithFormat:@"%@\n%@", base, [details componentsJoinedByString:@" · "]] : base;
    }
    if (_statusSpecifier) {
        [_statusSpecifier setProperty:_statusText forKey:@"footerText"];
        if (!_buildingSpecifiers) [_owner reloadSpecifier:_statusSpecifier animated:YES];
    }
}

@end
