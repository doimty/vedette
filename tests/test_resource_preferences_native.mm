#import "PreferencesHost.h"
#include <assert.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Extracted production methods/parser are compiled in a separate translation
// unit. Only Preferences presentation/reload is faked here. VDTShared.mm is real.
static unsigned posts;
static unsigned niceInitializations;
static unsigned niceSpecifierRequests;
extern "C" void VDTTestPostNotification(CFNotificationCenterRef center, CFStringRef name,
    const void *object, CFDictionaryRef info, Boolean immediately) {
    (void)center; (void)object; (void)info; (void)immediately;
    assert(CFEqual(name, CFSTR("com.udevs.vedette.prefschanged")));
    ++posts; // No notification reaches Darwin/system consumers.
}

@implementation PSSpecifier
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target
    set:(SEL)setter get:(SEL)getter detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit {
    (void)detail; (void)edit;
    PSSpecifier *specifier = [self new];
    specifier.name = name;
    specifier.target = target;
    specifier.setter = setter;
    specifier.getter = getter;
    specifier.cellType = cell;
    specifier.properties = [NSMutableDictionary new];
    return specifier;
}
+ (instancetype)emptyGroupSpecifier {
    return [self preferenceSpecifierNamed:@"" target:nil set:NULL get:NULL
        detail:Nil cell:PSGroupCell edit:Nil];
}
- (void)setProperty:(id)value forKey:(NSString *)key {
    if (value) self.properties[key] = value;
    else [self.properties removeObjectForKey:key];
}
- (id)propertyForKey:(NSString *)key { return self.properties[key]; }
- (void)setValues:(NSArray *)values titles:(NSArray *)titles {
    self.properties[@"values"] = values;
    self.properties[@"titles"] = titles;
}
@end

@implementation PSTextFieldSpecifier
- (void)setKeyboardType:(UIKeyboardType)type autoCaps:(UITextAutocapitalizationType)caps
    autoCorrection:(UITextAutocorrectionType)correction {
    self.properties[@"keyboardType"] = @(type);
    self.properties[@"autoCaps"] = @(caps);
    self.properties[@"autoCorrection"] = @(correction);
}
- (void)setPlaceholder:(NSString *)placeholder { self.properties[@"placeholder"] = placeholder; }
@end

@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style
    handler:(void (^)(UIAlertAction *))handler {
    (void)style; (void)handler;
    UIAlertAction *action = [self new]; action.title = title; return action;
}
@end

@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message
    preferredStyle:(UIAlertControllerStyle)style {
    (void)style;
    UIAlertController *alert = [self new];
    alert.title = title; alert.message = message; alert.actions = [NSMutableArray new];
    return alert;
}
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end

static void selector_gate(BOOL valid) {
    if (!valid) {
        fputs("NATIVE_MUTATION_REJECTED: getter selector/arity/response\n", stderr);
        exit(2);
    }
}

static id invoke_getter(VDTProcessConfiguration *owner, PSSpecifier *specifier) {
    selector_gate(specifier.getter == @selector(readResourceRuleValue:));
    selector_gate([owner respondsToSelector:specifier.getter]);
    NSMethodSignature *signature = [owner methodSignatureForSelector:specifier.getter];
    selector_gate(signature.numberOfArguments == 3);
    selector_gate(strcmp(signature.methodReturnType, @encode(id)) == 0);
    selector_gate(strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0);
    id (*getter)(id, SEL, PSSpecifier *) =
        (id (*)(id, SEL, PSSpecifier *))[owner methodForSelector:specifier.getter];
    return getter(owner, specifier.getter, specifier);
}

static void invoke_setter(VDTProcessConfiguration *owner, PSSpecifier *specifier, id value) {
    assert(specifier.setter == @selector(setResourceRuleValue:specifier:));
    assert([owner respondsToSelector:specifier.setter]);
    NSMethodSignature *signature = [owner methodSignatureForSelector:specifier.setter];
    assert(signature.numberOfArguments == 4);
    assert(strcmp(signature.methodReturnType, @encode(void)) == 0);
    assert(strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0);
    assert(strcmp([signature getArgumentTypeAtIndex:3], @encode(id)) == 0);
    void (*setter)(id, SEL, id, PSSpecifier *) =
        (void (*)(id, SEL, id, PSSpecifier *))[owner methodForSelector:specifier.setter];
    owner.displayedValue = value; // Simulate the control's optimistic edit.
    setter(owner, specifier.setter, value, specifier);
}

@implementation PSListController
- (void)reloadSpecifiers { ++self.reloadCount; }
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated {
    (void)animated;
    ++self.reloadCount;
    self.displayedValue = invoke_getter((VDTProcessConfiguration *)self, specifier);
}
- (void)presentViewController:(UIAlertController *)controller animated:(BOOL)animated
    completion:(void (^)(void))completion {
    (void)animated;
    self.lastAlert = controller; ++self.alertCount;
    if (completion) completion();
}
@end

@implementation VDTProcessConfiguration (CheckDisplaySentinel)
// This editor fixture fakes ONLY the added display host. Actual check result
// model and display wiring have their own required native / source CI gate.
- (NSArray *)vdtCheckResultSpecifiers { return @[]; }
- (void)vdtRefreshCheckResults {}
@end

@implementation VDTActionListController
@end
@implementation VDTNicePreferences
- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner {
    assert(owner != nil);
    if ((self = [super init])) ++niceInitializations;
    return self;
}
- (NSArray *)specifiers {
    ++niceSpecifierRequests;
    PSSpecifier *sentinel = [PSSpecifier emptyGroupSpecifier];
    [sentinel setProperty:@YES forKey:@"niceSentinel"];
    return @[sentinel];
}
@end

static VDTProcessConfiguration *owner_for_type(VDTConfigType type, NSString *identifier) {
    VDTProcessConfiguration *owner = [VDTProcessConfiguration new];
    owner.specifier = [PSSpecifier emptyGroupSpecifier];
    owner.specifier.name = @"Same label";
    [owner.specifier setProperty:@(type) forKey:@"configurationType"];
    [owner.specifier setProperty:identifier forKey:@"applicationIdentifier"];
    [owner.specifier setProperty:identifier forKey:@"daemonName"];
    [owner.specifier setProperty:identifier forKey:@"extensionIdentifier"];
    owner.parentController = [PSListController new];
    return owner;
}

static PSSpecifier *row(VDTProcessConfiguration *owner, NSString *section, NSString *key) {
    for (PSSpecifier *specifier in [owner specifiers]) {
        if ([[specifier propertyForKey:@"vdtRuleSection"] isEqual:section]
            && [[specifier propertyForKey:@"key"] isEqual:key]) return specifier;
    }
    assert(0 && "missing actual production resource row"); return nil;
}

static void assert_integer(id value, int64_t expected) {
    assert([value isKindOfClass:NSNumber.class]);
    assert(CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID());
    const char *type = [value objCType];
    assert(type && strlen(type) == 1 && strchr("cCsSiIlLqQ", type[0]));
    assert([value longLongValue] == expected);
}

static void assert_bool(id value, BOOL expected) {
    assert([value isKindOfClass:NSNumber.class]);
    assert(CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID());
    assert([value boolValue] == expected);
}

static void success(VDTProcessConfiguration *owner, PSSpecifier *specifier, id input, int64_t expected) {
    unsigned beforePosts = posts;
    NSUInteger beforeAlerts = owner.alertCount, beforeReloads = owner.reloadCount;
    NSUInteger beforeParentReloads = owner.parentController.reloadCount;
    invoke_setter(owner, specifier, input);
    assert(posts == beforePosts + 1);
    assert(owner.parentController.reloadCount == beforeParentReloads + 1);
    assert(owner.alertCount == beforeAlerts && owner.reloadCount == beforeReloads + 1);
    id observed = invoke_getter(owner, specifier);
    if ([[specifier propertyForKey:@"key"] isEqual:@"enabled"]) assert_bool(observed, expected != 0);
    else assert_integer(observed, expected);
    assert([owner.displayedValue isEqual:observed]);
    id persisted = valueForProcessResourceRuleKey([owner validIdentifier],
        [specifier propertyForKey:@"key"], nil, [owner configurationType],
        [specifier propertyForKey:@"vdtRuleSection"]);
    assert([persisted isEqual:observed]);
}

static void rejected(VDTProcessConfiguration *owner, PSSpecifier *specifier, id input) {
    NSData *beforeBytes = [NSData dataWithContentsOfFile:PREFS_PATH];
    NSDictionary *beforePrefs = getPrefs();
    id beforeValue = invoke_getter(owner, specifier);
    unsigned beforePosts = posts;
    NSUInteger beforeAlerts = owner.alertCount, beforeReloads = owner.reloadCount;
    invoke_setter(owner, specifier, input);
    assert(posts == beforePosts);
    assert([getPrefs() isEqual:beforePrefs]);
    assert([[NSData dataWithContentsOfFile:PREFS_PATH] isEqual:beforeBytes]);
    assert(owner.reloadCount == beforeReloads + 1 && owner.alertCount == beforeAlerts + 1);
    assert([owner.lastAlert.title isEqual:@"Invalid resource rule"]);
    assert(owner.lastAlert.actions.count == 1 && owner.lastAlert.message.length > 0);
    assert(beforeValue ? [owner.displayedValue isEqual:beforeValue] : owner.displayedValue == nil);
}

static void check_rows_and_nice(VDTProcessConfiguration *owner, BOOL supportsNice) {
    unsigned beforeNice = niceInitializations, beforeRequests = niceSpecifierRequests;
    NSArray *specifiers = [owner specifiers];
    assert(niceInitializations == beforeNice + (supportsNice ? 1 : 0));
    assert(niceSpecifierRequests == beforeRequests + (supportsNice ? 1 : 0));
    NSUInteger resources = 0, cpuRows = 0, sentinels = 0;
    for (PSSpecifier *specifier in specifiers) {
        if (specifier.setter == @selector(setProcessConfigValue:specifier:)) ++cpuRows;
        if ([[specifier propertyForKey:@"niceSentinel"] boolValue]) ++sentinels;
        NSString *section = [specifier propertyForKey:@"vdtRuleSection"];
        if (!section) continue;
        ++resources;
        assert(specifier.target == owner);
        assert([specifier propertyForKey:@"PostNotification"] == nil);
        assert([specifier propertyForKey:@"defaults"] == nil);
        NSString *key = [specifier propertyForKey:@"key"];
        assert([section isEqual:@"memoryRules"] || [section isEqual:@"jetsamRules"]);
        if ([key isEqual:@"enabled"]) {
            assert(specifier.cellType == PSSwitchCell);
            assert_bool([specifier propertyForKey:@"default"], NO);
        } else {
            assert(specifier.cellType == PSEditTextCell);
            assert([specifier isKindOfClass:PSTextFieldSpecifier.class]);
            if ([section isEqual:@"memoryRules"]) assert([key isEqual:@"active"] || [key isEqual:@"inactive"]);
            else assert([key isEqual:@"priority"]);
        }
        (void)invoke_getter(owner, specifier); // Real response, arity and return type.
    }
    assert(resources == 5 && cpuRows == 4 && sentinels == (supportsNice ? 1u : 0u));
    assert(![owner respondsToSelector:@selector(readResourceRuleValue:specifier:)]);
    assert([owner specifiers] == specifiers); // Cache must not create extra nice owner.
    assert(niceInitializations == beforeNice + (supportsNice ? 1 : 0));
}

static void numeric_cases(VDTProcessConfiguration *owner, NSString *section, NSString *key, BOOL memory) {
    PSSpecifier *specifier = row(owner, section, key);
    for (NSString *valid in @[@"-1", @"0", @"+1", @"00042", @"2147483647"])
        success(owner, specifier, valid, [valid longLongValue]);
    success(owner, specifier, @120, 120);
    if (!memory) {
        // Advanced raw save domain deliberately not a claim of applicable band.
        for (NSString *valid in @[@"-2147483648", @"-2", @"21", @"210", @"999"])
            success(owner, specifier, valid, [valid longLongValue]);
        success(owner, specifier, @(INT32_MIN), INT32_MIN);
    } else {
        rejected(owner, specifier, @"-2");
        rejected(owner, specifier, @"-2147483648");
    }
    NSArray *invalid = @[@"", @" ", @" 12", @"12 ", @"12\n", @"+", @"-", @"--1", @"1x", @"x1", @"1 2",
        @"1.0", @"1.5", @"1e2", @"0x10", @"１２", @"−1", @"2147483648", @"-2147483649",
        @"9223372036854775807", @"18446744073709551615", @"999999999999999999999999999999",
        @YES, @NO, @1.5, @(-1.25), @(LLONG_MAX), @(LLONG_MIN), @(ULLONG_MAX),
        [NSNumber numberWithDouble:INFINITY], [NSNumber numberWithDouble:NAN],
        [NSDecimalNumber decimalNumberWithString:@"1.0"], NSNull.null, @[], @{}];
    for (id invalidValue in invalid) rejected(owner, specifier, invalidValue);
    unichar embeddedNull[] = {'1', 0, '2'};
    rejected(owner, specifier, [NSString stringWithCharacters:embeddedNull length:3]);
    rejected(owner, specifier, nil);
}

static void switch_cases(VDTProcessConfiguration *owner, NSString *section) {
    PSSpecifier *specifier = row(owner, section, @"enabled");
    success(owner, specifier, @YES, 1);
    success(owner, specifier, @NO, 0);
    for (id invalid in @[@0, @1, @2, @(-1), @0.0, @1.0, @"YES", @"true", @"1", @"0", @"", NSNull.null, @[], @{}])
        rejected(owner, specifier, invalid);
    rejected(owner, specifier, nil);
}

static void actual_write_failure(VDTProcessConfiguration *owner, PSSpecifier *specifier) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSData *beforeBytes = [NSData dataWithContentsOfFile:PREFS_PATH];
    NSDictionary *beforePrefs = getPrefs();
    id beforeValue = invoke_getter(owner, specifier);
    unsigned beforePosts = posts;
    NSUInteger beforeAlerts = owner.alertCount, beforeReloads = owner.reloadCount;
    NSError *error = nil;
    // Darwin user-immutable fixture file: real atomic write failure, with old
    // contents still readable. No chmod/sudo/system paths or fake store result.
    assert([fm setAttributes:@{NSFileImmutable: @YES} ofItemAtPath:PREFS_PATH error:&error]);
    @try {
        assert(![@{@"probe": @1} writeToFile:PREFS_PATH atomically:YES]);
        invoke_setter(owner, specifier, @"777");
        assert(posts == beforePosts);
        assert([getPrefs() isEqual:beforePrefs]);
        assert([[NSData dataWithContentsOfFile:PREFS_PATH] isEqual:beforeBytes]);
        assert(owner.alertCount == beforeAlerts + 1 && owner.reloadCount == beforeReloads + 1);
        assert([owner.lastAlert.title isEqual:@"Resource rule save failed"]);
        assert([owner.lastAlert.message containsString:@"previous saved value"]);
        assert([owner.displayedValue isEqual:beforeValue]);
        assert([invoke_getter(owner, specifier) isEqual:beforeValue]);
    } @finally {
        error = nil;
        assert([fm setAttributes:@{NSFileImmutable: @NO} ofItemAtPath:PREFS_PATH error:&error]);
    }
    // Recovery: same production methods persist again after fixture fault clears.
    success(owner, specifier, @"778", 778);
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"vdt-resource-preferences-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
        assert(setenv("VDT_RESOURCE_PREFS_FIXTURE_ROOT", root.UTF8String, 1) == 0);
        NSDictionary *base = @{
            @"enabled": @YES, @"sentinel": @"untouched",
            @"appConfigs": @[@{@"bundleIdentifier": @"same.id", @"enabled": @YES,
                @"percentage": @80, @"niceEnabled": @YES, @"niceValue": @(-5)}],
            @"daemonConfigs": @[@{@"daemonName": @"same.id", @"enabled": @NO,
                @"percentage": @40, @"niceEnabled": @YES, @"niceValue": @10}],
            @"extensionConfigs": @[@{@"extensionIdentifier": @"same.id", @"enabled": @NO, @"percentage": @20}]
        };
        assert([base writeToFile:PREFS_PATH atomically:YES]);
        check_rows_and_nice(owner_for_type((VDTConfigType)999, @"same.id"), NO);
        for (NSNumber *kind in @[@(VDTConfigTypeApp), @(VDTConfigTypeDaemon), @(VDTConfigTypeExtension)]) {
            VDTConfigType type = (VDTConfigType)kind.unsignedLongValue;
            VDTProcessConfiguration *owner = owner_for_type(type, @"same.id");
            check_rows_and_nice(owner, YES);
            PSSpecifier *active = row(owner, @"memoryRules", @"active");
            assert(invoke_getter(owner, active) == nil); // Same id in other type cannot leak.
            assert_bool(invoke_getter(owner, row(owner, @"memoryRules", @"enabled")), NO);
            success(owner, active, @"256", 256);
            success(owner, row(owner, @"memoryRules", @"inactive"), @"128", 128);
            success(owner, row(owner, @"jetsamRules", @"priority"), @"-2", -2);
            VDTProcessConfiguration *fresh = owner_for_type(type, @"same.id");
            assert_integer(invoke_getter(fresh, row(fresh, @"memoryRules", @"active")), 256);
            assert_integer(invoke_getter(fresh, row(fresh, @"memoryRules", @"inactive")), 128);
            assert_integer(invoke_getter(fresh, row(fresh, @"jetsamRules", @"priority")), -2);
            numeric_cases(owner, @"memoryRules", @"active", YES);
            numeric_cases(owner, @"memoryRules", @"inactive", YES);
            numeric_cases(owner, @"jetsamRules", @"priority", NO);
            switch_cases(owner, @"memoryRules");
            switch_cases(owner, @"jetsamRules");
        }
        NSDictionary *prefs = getPrefs();
        for (NSString *section in @[@"memoryRules", @"jetsamRules"]) {
            NSArray *records = prefs[section];
            assert(records.count == 3);
            for (NSDictionary *record in records) {
                assert_integer(record[@"schema"], 1);
                NSUInteger identities = (record[@"bundleIdentifier"] != nil)
                    + (record[@"daemonName"] != nil) + (record[@"extensionIdentifier"] != nil);
                assert(identities == 1); // App/Daemon/Extension identities kept separate.
            }
        }
        VDTProcessConfiguration *app = owner_for_type(VDTConfigTypeApp, @"same.id");
        PSSpecifier *bad = [PSSpecifier preferenceSpecifierNamed:@"Invalid binding" target:app
            set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:)
            detail:Nil cell:PSEditTextCell edit:Nil];
        [bad setProperty:@"fallback" forKey:@"default"];
        for (NSArray *binding in @[@[@"percentage", @"memoryRules"], @[@"active", @"appConfigs"],
            @[@"niceValue", @"daemonConfigs"], @[@"priority", @"memoryRules"],
            @[@"active", @"jetsamRules"], @[@"", @"memoryRules"], @[@12, @[]]]) {
            [bad setProperty:binding[0] forKey:@"key"];
            [bad setProperty:binding[1] forKey:@"vdtRuleSection"];
            rejected(app, bad, @"99");
        }
        actual_write_failure(app, row(app, @"memoryRules", @"active"));
        actual_write_failure(app, row(app, @"jetsamRules", @"priority"));

        // Another real storage NO path: invalid identity/type, no optimistic success.
        VDTProcessConfiguration *unknown = owner_for_type((VDTConfigType)999, @"same.id");
        PSSpecifier *unknownRow = row(unknown, @"memoryRules", @"active");
        unsigned beforePosts = posts;
        NSDictionary *beforeUnknown = getPrefs();
        invoke_setter(unknown, unknownRow, @"99");
        assert(posts == beforePosts && [getPrefs() isEqual:beforeUnknown]);
        assert(unknown.displayedValue == nil && unknown.reloadCount == 1 && unknown.alertCount == 1);
        assert([unknown.lastAlert.title isEqual:@"Resource rule save failed"]);

        VDTProcessConfiguration *protectedApp = owner_for_type(VDTConfigTypeApp, @"com.apple.Preferences");
        for (PSSpecifier *specifier in [protectedApp specifiers]) {
            if ([specifier propertyForKey:@"vdtRuleSection"])
                assert_bool([specifier propertyForKey:@"enabled"], NO);
        }
        prefs = getPrefs();
        for (NSString *key in @[@"enabled", @"sentinel", @"appConfigs", @"daemonConfigs", @"extensionConfigs"])
            assert([prefs[key] isEqual:base[key]]); // Includes all original CPU/nice fields.
        assert([fm removeItemAtPath:root error:nil]);
        printf("PASS: real extracted production specifiers/getter/setter/parser + VDTShared Foundation plist roundtrip; "
               "App/Daemon/Extension, NSNumber domains, invalid-input no-change, "
               "atomic write-failure feedback/readback/no-notification/recovery; %u successful saves\n", posts);
    }
    return 0;
}
