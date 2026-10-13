// Independent-rules native fixture (part of tests/test_independent_rules_native.py).
//
// Real production under test: VDTShared.mm, VDTNiceShared.mm, VDTNiceStore.c and
// the verbatim-extracted VDTListPresentation.m / VDTNicePreferences.m /
// VDTProcessConfiguration.m methods compiled by the Python runner.
// Only the Preferences presentation host, alert objects and notification
// counters are faked. No UIKit, no real device, no privileged path.
#import "PreferencesHost.h"
#import "VDTNiceShared.h"
#import "vedetteprefs/VDTListPresentation.h"
#import "vedetteprefs/VDTNicePreferences.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *gRoot;

extern "C" NSString *VDTTestJbroot(NSString *path) {
    return [gRoot stringByAppendingString:path];
}

static void fixture_fail(const char *tag, const char *detail, int line) {
    fprintf(stderr, "FIXTURE_FAIL:%s line %d: %s\n", tag, line, detail);
    abort();
}
#define REQ(tag, ...) do { if (!(__VA_ARGS__)) fixture_fail(tag, #__VA_ARGS__, __LINE__); } while (0)

static unsigned posts;      // renamed CFNotificationCenterPostNotification
static unsigned nicePosts;  // renamed notify_post

extern "C" void VDTTestPostNotification(CFNotificationCenterRef center, CFStringRef name,
    const void *object, CFDictionaryRef info, Boolean immediately) {
    (void)center; (void)object; (void)info; (void)immediately;
    REQ("fixture.notify-name", CFEqual(name, CFSTR("com.udevs.vedette.prefschanged")));
    ++posts; // Counted only; no notification reaches any system consumer.
}

extern "C" int VDTTestNotifyPost(const char *name) {
    (void)name; ++nicePosts; return 0;
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
- (void)setButtonAction:(SEL)action { _buttonAction = action; }
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
    (void)style;
    UIAlertAction *action = [self new];
    action.title = title;
    action.handler = handler;
    return action;
}
@end

@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message
    preferredStyle:(UIAlertControllerStyle)style {
    (void)style;
    UIAlertController *alert = [self new];
    alert.title = title;
    alert.message = message;
    alert.actions = [NSMutableArray new];
    return alert;
}
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end

@implementation PSListController
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated {
    (void)animated;
    if (specifier) [self.reloadLog addObject:specifier];
    ++self.reloadCount;
}
- (void)reloadSpecifiers { ++self.reloadSpecifiersCount; }
- (id)_parentController { return _parentController; }
- (void)set_parentController:(id)parent { _parentController = parent; }
- (void)presentViewController:(UIAlertController *)controller animated:(BOOL)animated
    completion:(void (^)(void))completion {
    (void)animated;
    self.lastAlert = controller; ++self.alertCount;
    if (completion) completion();
}
@end

@implementation VDTActionListController
@end

@implementation VDTNiceValueListController
@end

// Declarations only: implementations come from the verbatim-extracted
// production text compiled in the sibling translation unit.
@interface VDTNicePreferences (FixtureActors)
- (void)removeIndependentNiceRule;
- (void)confirmFollowContainingAppNice;
- (void)updateInheritancePresentation;
@end

// MARK: - fixture helpers (no production logic duplicated here)

static NSString *sec(VDTConfigType t) {
    switch (t) {
        case VDTConfigTypeApp: return @"appConfigs";
        case VDTConfigTypeDaemon: return @"daemonConfigs";
        default: return @"extensionConfigs";
    }
}
static NSString *idk(VDTConfigType t) {
    switch (t) {
        case VDTConfigTypeApp: return @"bundleIdentifier";
        case VDTConfigTypeDaemon: return @"daemonName";
        default: return @"extensionIdentifier";
    }
}
static id CFBOOL(BOOL value) { return value ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse; }

static NSDictionary *rec(VDTConfigType t, NSString *identifier, NSDictionary *fields) {
    NSMutableDictionary *entry = [@{idk(t): identifier} mutableCopy];
    [entry addEntriesFromDictionary:fields];
    return entry;
}
static NSDictionary *one(VDTConfigType t, NSString *identifier, NSDictionary *fields) {
    return @{sec(t): @[rec(t, identifier, fields)]};
}
static NSDictionary *rows(VDTConfigType t, NSArray *records) { return @{sec(t): records}; }
static NSDictionary *booleans(NSArray *pairs) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSArray *pair in pairs) d[pair[0]] = pair[1];
    return d;
}
static NSDictionary *resource(VDTConfigType t, NSString *identifier, NSString *section, NSDictionary *fields) {
    return @{section: @[rec(t, identifier, fields)]};
}
static NSDictionary *meta(NSString *extensionIdentifier, NSString *host) {
    return @{@"extensionIdentifier": extensionIdentifier, @"containingAppIdentifier": host ?: @""};
}

static void write_prefs(NSDictionary *prefs) {
    NSError *error = nil;
    BOOL made = [[NSFileManager defaultManager] createDirectoryAtPath:
        [PREFS_PATH stringByDeletingLastPathComponent] withIntermediateDirectories:YES
        attributes:nil error:&error] || [[NSFileManager defaultManager] fileExistsAtPath:PREFS_PATH];
    REQ("fixture.preps", made);
    REQ("fixture.write", [prefs writeToFile:PREFS_PATH atomically:YES]);
}
static NSDictionary *read_prefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH] ?: @{};
}
static NSDictionary *entry_in(NSDictionary *prefs, VDTConfigType t, NSString *identifier) {
    for (NSDictionary *entry in prefs[sec(t)] ?: @[])
        if ([entry isKindOfClass:NSDictionary.class] && [entry[idk(t)] isEqual:identifier]) return entry;
    return nil;
}
static BOOL nice_fields_present(NSDictionary *entry) {
    return entry[VDT_NICE_ENABLED_KEY] || entry[VDT_NICE_VALUE_KEY] || entry[VDT_NICE_REVISION_KEY];
}

static void raw_bool(id value, BOOL expected) {
    REQ("store.raw-bool", [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue] == expected);
}
static void raw_int(id value, long long expected) {
    const char *type = [value isKindOfClass:NSNumber.class] ? [value objCType] : NULL;
    REQ("store.raw-int", type && strlen(type) == 1 && strchr("cCsSiIlLqQ", type[0]) &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value longLongValue] == expected);
}

static VDTProcessConfiguration *owner_for(VDTConfigType type, NSString *identifier, NSDictionary *metadata) {
    VDTProcessConfiguration *owner = [VDTProcessConfiguration new];
    owner.specifier = [PSSpecifier emptyGroupSpecifier];
    owner.specifier.name = @"Test row";
    [owner.specifier setProperty:@(type) forKey:@"configurationType"];
    [owner.specifier setProperty:identifier forKey:@"applicationIdentifier"];
    [owner.specifier setProperty:identifier forKey:@"daemonName"];
    [owner.specifier setProperty:identifier forKey:@"extensionIdentifier"];
    if (metadata) [owner.specifier setProperty:metadata forKey:@"vdtExtensionMetadata"];
    return owner;
}

static void arity_gate(BOOL valid, const char *detail) {
    if (!valid) {
        fprintf(stderr, "FIXTURE_FAIL:arity %s\n", detail);
        abort();
    }
}
static PSSpecifier *nice_row(NSArray *rows, NSString *key) {
    for (PSSpecifier *specifier in rows)
        if ([[specifier propertyForKey:@"key"] isEqual:key]) return specifier;
    return nil;
}
static id nice_get(VDTNicePreferences *nice, PSSpecifier *specifier) {
    arity_gate(specifier.getter == @selector(readPreferenceValue:), "getter selector");
    arity_gate([nice respondsToSelector:specifier.getter], "getter response");
    NSMethodSignature *signature = [nice methodSignatureForSelector:specifier.getter];
    arity_gate(signature.numberOfArguments == 3, "getter arity");
    arity_gate(strcmp(signature.methodReturnType, @encode(id)) == 0, "getter return type");
    arity_gate(strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0, "getter argument");
    id (*getter)(id, SEL, PSSpecifier *) =
        (id (*)(id, SEL, PSSpecifier *))[nice methodForSelector:specifier.getter];
    return getter(nice, specifier.getter, specifier);
}
static void nice_set(VDTNicePreferences *nice, PSSpecifier *specifier, id value) {
    arity_gate(specifier.setter == @selector(setPreferenceValue:specifier:), "setter selector");
    arity_gate([nice respondsToSelector:specifier.setter], "setter response");
    NSMethodSignature *signature = [nice methodSignatureForSelector:specifier.setter];
    arity_gate(signature.numberOfArguments == 4, "setter arity");
    arity_gate(strcmp(signature.methodReturnType, @encode(void)) == 0, "setter return type");
    arity_gate(strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) == 0, "setter value");
    arity_gate(strcmp([signature getArgumentTypeAtIndex:3], @encode(id)) == 0, "setter specifier");
    void (*setter)(id, SEL, id, PSSpecifier *) =
        (void (*)(id, SEL, id, PSSpecifier *))[nice methodForSelector:specifier.setter];
    setter(nice, specifier.setter, value, specifier);
}

// MARK: - four independent pins x three types (CPU off / global off / negatives)

static void check_pins(void) {
    const VDTConfigType types[] = {VDTConfigTypeApp, VDTConfigTypeDaemon, VDTConfigTypeExtension};
    const char *names[] = {"app", "daemon", "extension"};
    NSString *identifiers[] = {@"com.pin.app", @"pin.daemon", @"com.pin.ext"};
    for (NSArray *pair in @[@[@"pin.nice-only", @"niceEnabled"], @[@"pin.memory-only", @"memoryRules"],
                            @[@"pin.jetsam-only", @"jetsamRules"]]) {
        NSString *tag = pair[0];
        NSString *kind = pair[1];
        for (int i = 0; i < 3; ++i) {
            NSString *exact = [NSString stringWithFormat:@"%@.%s", tag, names[i]];
            NSDictionary *prefs = [kind isEqual:@"niceEnabled"]
                ? one(types[i], identifiers[i], @{kind: CFBOOL(YES)})
                : resource(types[i], identifiers[i], kind, @{@"enabled": CFBOOL(YES)});
            REQ(exact.UTF8String, VDTListConfigurationEnabled(identifiers[i], types[i], prefs));
        }
    }
    // Numeric/bad Boolean shapes must not pin for nice or resource switches.
    REQ("pin.numeric-not.ext", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{@"niceEnabled": @1})));
    REQ("pin.numeric-not.res", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        resource(VDTConfigTypeExtension, @"com.pin.ext", @"memoryRules", @{@"enabled": @1})));
    REQ("pin.badbool-not", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{@"niceEnabled": @"true"})));
    REQ("pin.badbool-null", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{@"niceEnabled": NSNull.null})));
    // Legacy CPU switch keeps NSNumber/NSString boolValue semantics.
    REQ("pin.cpu-legacy-string", VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{@"enabled": @"1"})));
    REQ("pin.cpu-legacy-number", VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{@"enabled": @1})));
    // CPU disabled on the extension while another family is independently enabled.
    REQ("pin.cpu-off-nice", VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        rows(VDTConfigTypeExtension, @[
            rec(VDTConfigTypeExtension, @"com.pin.ext", @{@"enabled": CFBOOL(NO), @"percentage": @80}),
            rec(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})])));
    REQ("pin.disabled-no", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(NO)})));
    // A saved nice value alone never pins; a disabled switch blocks inheritance.
    REQ("pin.nice-value-only-not", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_VALUE_KEY: @5})));
    REQ("pin.unknown-id-not", !VDTListConfigurationEnabled(nil, VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})));
    REQ("pin.empty-id-not", !VDTListConfigurationEnabled(@"", VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})));
    REQ("pin.nonstring-id-not", !VDTListConfigurationEnabled((id)@(3), VDTConfigTypeExtension,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})));
    REQ("pin.bad-type-not", !VDTListConfigurationEnabled(@"com.pin.ext", (VDTConfigType)999,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})));
    REQ("pin.negative-type-not", !VDTListConfigurationEnabled(@"com.pin.ext", (VDTConfigType)-1,
        one(VDTConfigTypeExtension, @"com.pin.ext", @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})));
    // The global runtime switch does not move configuration grouping.
    NSMutableDictionary *globalOff = [one(VDTConfigTypeExtension, @"com.pin.ext",
        @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)}) mutableCopy];
    globalOff[@"enabled"] = CFBOOL(NO);
    REQ("pin.global-off", VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension, globalOff));
    // Host-inherited nice is not an independent pin.
    NSDictionary *inherited = booleans(@[@[@"appConfigs", @[rec(VDTConfigTypeApp, @"com.pin.host",
        @{VDT_NICE_ENABLED_KEY: CFBOOL(YES), VDT_NICE_VALUE_KEY: @9})]],
        @[@"extensionConfigs", @[rec(VDTConfigTypeExtension, @"com.pin.ext", @{})]]]);
    REQ("pin.host-inherit-not", !VDTListConfigurationEnabled(@"com.pin.ext", VDTConfigTypeExtension, inherited));
    NSDictionary *effective = VDTNiceEffectiveRule(@"com.pin.ext", VDTConfigTypeExtension, @"com.pin.host", inherited);
    REQ("pin.host-inherit-rule", [effective[@"inherited"] boolValue] && [effective[@"requestedEnabled"] boolValue] &&
        [effective[@"sourceIdentifier"] isEqual:@"com.pin.host"] && [effective[@"present"] boolValue] &&
        !VDTNiceHasIndependentRule(@"com.pin.ext", VDTConfigTypeExtension, inherited));
    REQ("pin.host-inherit-rule2", [effective[@"inherited"] boolValue] &&
        [effective[@"sourceType"] isEqual:@(VDTConfigTypeApp)]);
}

// MARK: - mixed duplicate families (the fixed Shared getter)

static void check_mixed_duplicates(VDTProcessConfiguration *owner, VDTNicePreferences *nice,
                                   PSSpecifier *enabledSpecifier) {
    NSString *identifier = @"com.mixed.ext";
    NSString *host = @"com.mixed.host";
    // CPU-only row first, independent nice second.
    NSDictionary *cpuFirst = rows(VDTConfigTypeExtension, @[
        rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(NO), @"percentage": @80}),
        rec(VDTConfigTypeExtension, identifier, @{VDT_NICE_ENABLED_KEY: CFBOOL(YES), VDT_NICE_VALUE_KEY: @5})]);
    id niceValue = valueForProcessConfigKeyWithPrefs(identifier, VDT_NICE_ENABLED_KEY, @NO,
        VDTConfigTypeExtension, cpuFirst);
    REQ("mixed.cpu-first", [niceValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)niceValue) == CFBooleanGetTypeID() && [niceValue boolValue]);
    id cpuValue = valueForProcessConfigKeyWithPrefs(identifier, @"enabled", @NO,
        VDTConfigTypeExtension, cpuFirst);
    REQ("mixed.cpu-first-cpu", [cpuValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)cpuValue) == CFBooleanGetTypeID() && ![cpuValue boolValue]);
    REQ("mixed.cpu-first-pin", VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, cpuFirst));
    NSDictionary *rule = VDTNiceEffectiveRule(identifier, VDTConfigTypeExtension, host, cpuFirst);
    REQ("mixed.cpu-first-rule", [rule[@"present"] boolValue] && [rule[@"requestedEnabled"] boolValue] &&
        ![rule[@"inherited"] boolValue] && [rule[@"sourceIdentifier"] isEqual:identifier]);
    // Real UI read path over the same file-backed prefs.
    write_prefs(cpuFirst);
    REQ("mixed.ui", [nice_get(nice, enabledSpecifier) boolValue]);
    // Saving a switch must target that same family row, not manufacture a
    // new earlier niceValue=0 inside the CPU-only row.
    NSError *saveError = nil;
    REQ("mixed.save", VDTNiceSavePreference(identifier, VDTConfigTypeExtension,
        VDT_NICE_ENABLED_KEY, CFBOOL(YES), &saveError));
    NSDictionary *saved = read_prefs();
    NSDictionary *savedRule = VDTNiceEffectiveRule(identifier, VDTConfigTypeExtension, host, saved);
    REQ("mixed.save-preserves-value", [savedRule[@"value"] isEqual:@5]);
    NSArray *savedRows = saved[@"extensionConfigs"];
    REQ("mixed.save-preserves-cpu", savedRows.count == 2 &&
        !nice_fields_present(savedRows[0]) && [savedRows[0][@"percentage"] isEqual:@80]);
    // Nice-only row first, independent CPU second.
    NSDictionary *niceFirst = rows(VDTConfigTypeExtension, @[
        rec(VDTConfigTypeExtension, identifier, @{VDT_NICE_ENABLED_KEY: CFBOOL(YES), VDT_NICE_VALUE_KEY: @5}),
        rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(YES)})]);
    id cpuSecond = valueForProcessConfigKeyWithPrefs(identifier, @"enabled", @NO,
        VDTConfigTypeExtension, niceFirst);
    REQ("mixed.cpu-second", [cpuSecond isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)cpuSecond) == CFBooleanGetTypeID() && [cpuSecond boolValue]);
    REQ("mixed.cpu-second-pin", VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, niceFirst));
    // First family intent (disabled / partial / invalid) blocks later same-family enabled.
    NSDictionary *blockedCpu = rows(VDTConfigTypeExtension, @[
        rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(NO)}),
        rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(YES)})]);
    REQ("mixed.block-cpu", !VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, blockedCpu));
    NSDictionary *partialCpu = rows(VDTConfigTypeExtension, @[
        rec(VDTConfigTypeExtension, identifier, @{@"percentage": @50}),
        rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(YES)})]);
    REQ("mixed.block-cpu-partial", !VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, partialCpu));
    NSDictionary *blockedNice = rows(VDTConfigTypeExtension, @[
        rec(VDTConfigTypeExtension, identifier, @{VDT_NICE_ENABLED_KEY: CFBOOL(NO)}),
        rec(VDTConfigTypeExtension, identifier, @{VDT_NICE_ENABLED_KEY: CFBOOL(YES), VDT_NICE_VALUE_KEY: @5})]);
    REQ("mixed.block-nice", !VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, blockedNice));
    NSDictionary *invalidNice = rows(VDTConfigTypeExtension, @[
        rec(VDTConfigTypeExtension, identifier, @{VDT_NICE_ENABLED_KEY: @"invalid"}),
        rec(VDTConfigTypeExtension, identifier, @{VDT_NICE_ENABLED_KEY: CFBOOL(YES)})]);
    REQ("mixed.block-invalid", !VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, invalidNice));
}

// MARK: - subtitles and grouping

static void check_subtitles(void) {
    NSString *identifier = @"com.sub.ext";
    NSDictionary *resourceOnly = booleans(@[@[@"extensionConfigs", @[rec(VDTConfigTypeExtension, identifier, @{})]],
        @[@"memoryRules", @[rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(YES)})]]]);
    REQ("subtitle.resource-only", [VDTListExtensionSubtitleKey(identifier, resourceOnly)
        isEqual:@"CPU follows app; independent rules enabled"]);
    NSDictionary *cpuDisabledNice = one(VDTConfigTypeExtension, identifier,
        @{@"enabled": CFBOOL(NO), @"percentage": @80, VDT_NICE_ENABLED_KEY: CFBOOL(YES)});
    REQ("subtitle.cpu-disabled-nice", [VDTListExtensionSubtitleKey(identifier, cpuDisabledNice)
        isEqual:@"Independent configurations enabled"]);
    REQ("subtitle.cpu-own", [VDTListExtensionSubtitleKey(identifier,
        one(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(YES)}))
        isEqual:@"Independent configurations enabled"]);
    REQ("subtitle.none", [VDTListExtensionSubtitleKey(identifier, @{})
        isEqual:@"Follow containing app"]);
    REQ("subtitle.nice-value-only", [VDTListExtensionSubtitleKey(identifier,
        one(VDTConfigTypeExtension, identifier, @{VDT_NICE_VALUE_KEY: @5}))
        isEqual:@"CPU follows app; independent rules off"]);
}

static void check_grouping(void) {
    write_prefs(booleans(@[@[@"appConfigs", @[
        rec(VDTConfigTypeApp, @"com.group.alpha", @{@"enabled": CFBOOL(YES)}),
        rec(VDTConfigTypeApp, @"com.group.delta", @{@"enabled": CFBOOL(YES)})]]]));
    NSMutableArray *source = [NSMutableArray array];
    [source addObject:[PSSpecifier emptyGroupSpecifier]];
    for (NSString *identifier in @[@"com.group.bravo", @"com.group.alpha", @"com.group.charlie",
                                   @"com.group.bravo", @"com.group.delta"]) {
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:identifier target:nil
            set:NULL get:NULL detail:Nil cell:PSSwitchCell edit:Nil];
        [row setProperty:identifier forKey:@"applicationIdentifier"];
        [source addObject:row];
    }
    PSSpecifier *orphan = [PSSpecifier preferenceSpecifierNamed:@"orphan" target:nil
        set:NULL get:NULL detail:Nil cell:PSSwitchCell edit:Nil];
    [source addObject:orphan];
    NSUInteger sourceCount = source.count;
    NSArray *ordered = VDTGroupedListSpecifiers(source, @"applicationIdentifier", VDTConfigTypeApp,
        PSSpecifier.class, nil, @"empty.key");
    REQ("group.order", ordered.count == 6 && ((PSSpecifier *)ordered[0]).cellType == PSGroupCell &&
        ((PSSpecifier *)ordered[1]).name.length > 0 && ((PSSpecifier *)ordered[3]).cellType == PSGroupCell);
    NSArray *names = @[((PSSpecifier *)ordered[1]).name, ((PSSpecifier *)ordered[2]).name,
                       ((PSSpecifier *)ordered[4]).name, ((PSSpecifier *)ordered[5]).name];
    REQ("group.order-names", [names isEqualToArray:@[@"com.group.alpha", @"com.group.delta",
        @"com.group.bravo", @"com.group.charlie"]]);
    id snapshot = [(PSSpecifier *)ordered[1] propertyForKey:@"vdtListPrefsSnapshot"];
    REQ("group.snapshot", snapshot && snapshot == [(PSSpecifier *)ordered[5] propertyForKey:@"vdtListPrefsSnapshot"] &&
        [snapshot isEqual:getPrefs()]);
    REQ("group.footer", [[(PSSpecifier *)ordered[0] propertyForKey:@"footerText"]
        hasPrefix:@"Grouping reflects saved per-process switches"]);
    NSArray *again = VDTGroupedListSpecifiers(source, @"applicationIdentifier", VDTConfigTypeApp,
        PSSpecifier.class, nil, @"empty.key");
    REQ("group.stable", again.count == ordered.count);
    for (NSUInteger i = 0; i < again.count; ++i) {
        NSString *left = ((PSSpecifier *)again[i]).name;
        NSString *right = ((PSSpecifier *)ordered[i]).name;
        REQ("group.stable-name", left == right || [left isEqual:right]);
    }
    REQ("group.source-untouched", source.count == sourceCount);
    NSArray *searched = VDTGroupedListSpecifiers(source, @"applicationIdentifier", VDTConfigTypeApp,
        PSSpecifier.class, ^BOOL(PSSpecifier *specifier) { return ![specifier.name isEqual:@"com.group.alpha"]; },
        @"empty.key");
    REQ("group.search", searched.count == 5);
    for (PSSpecifier *specifier in searched)
        REQ("group.search-name", ![specifier.name isEqual:@"com.group.alpha"]);
    NSArray *empty = VDTGroupedListSpecifiers(@[], @"applicationIdentifier", VDTConfigTypeApp,
        PSSpecifier.class, nil, @"empty.key");
    REQ("group.empty", empty.count == 1 && [[(PSSpecifier *)empty[0] propertyForKey:@"footerText"] isEqual:@"empty.key"]);
}

// MARK: - nice UI: production save path, owner/parent refresh, no auto-enable

static PSSpecifier *follow_row(NSArray *rows) {
    for (PSSpecifier *specifier in rows)
        if (specifier.buttonAction == @selector(confirmFollowContainingAppNice)) return specifier;
    return nil;
}

static void check_nice_ui(void) {
    write_prefs(@{});
    NSString *identifier = @"com.ind.ext";
    NSString *host = @"com.ind.host";
    VDTProcessConfiguration *owner = owner_for(VDTConfigTypeExtension, identifier, meta(identifier, host));
    PSListController *parent = [PSListController new];
    [owner setValue:parent forKey:@"_parentController"];
    VDTNicePreferences *nice = [owner vdtNicePreferences];
    NSArray *niceRows = [nice specifiers];
    PSSpecifier *enabledSpecifier = nice_row(niceRows, VDT_NICE_ENABLED_KEY);
    PSSpecifier *valueSpecifier = nice_row(niceRows, VDT_NICE_VALUE_KEY);
    PSSpecifier *followSpecifier = follow_row(niceRows);
    REQ("nice.rows", enabledSpecifier != nil && valueSpecifier != nil && followSpecifier != nil);

    unsigned beforeNicePosts = nicePosts, beforePosts = posts;
    NSUInteger beforeReloads = owner.reloadCount;
    nice_set(nice, enabledSpecifier, CFBOOL(YES));
    NSDictionary *entry = entry_in(read_prefs(), VDTConfigTypeExtension, identifier);
    REQ("nice.save", entry != nil && nicePosts == beforeNicePosts + 1 && posts == beforePosts);
    raw_bool(entry[VDT_NICE_ENABLED_KEY], YES);
    raw_int(entry[VDT_NICE_VALUE_KEY], 0); // enabling pre-stores value 0, never the reverse
    BOOL sawInheritanceReload = NO;
    for (PSSpecifier *specifier in owner.reloadLog)
        if ([[specifier propertyForKey:@"footerText"] hasPrefix:@"Without its own nice fields"])
            sawInheritanceReload = YES;
    REQ("nice.owner-reload", owner.reloadCount >= beforeReloads + 3 && sawInheritanceReload);
    REQ("nice.parent-reload", parent.reloadSpecifiersCount == 1);
    BOOL inheritanceNamed = NO;
    for (PSSpecifier *specifier in niceRows)
        if ([specifier.name isEqual:@"Independent nice rule"]) inheritanceNamed = YES;
    REQ("nice.own-state", [[followSpecifier propertyForKey:@"enabled"] boolValue] && inheritanceNamed);

    NSString *other = @"com.ind.ext2";
    VDTProcessConfiguration *owner2 = owner_for(VDTConfigTypeExtension, other, meta(other, host));
    VDTNicePreferences *nice2 = [owner2 vdtNicePreferences];
    NSArray *rows2 = [nice2 specifiers];
    PSSpecifier *enabled2 = nice_row(rows2, VDT_NICE_ENABLED_KEY);
    PSSpecifier *value2 = nice_row(rows2, VDT_NICE_VALUE_KEY);
    unsigned postsBefore = nicePosts;
    nice_set(nice2, value2, @7);
    NSDictionary *entry2 = entry_in(read_prefs(), VDTConfigTypeExtension, other);
    REQ("nice.value-no-autoenable", entry2 != nil && nicePosts == postsBefore + 1 &&
        entry2[VDT_NICE_ENABLED_KEY] == nil && [entry2[VDT_NICE_VALUE_KEY] isEqual:@7] &&
        ![nice_get(nice2, enabled2) boolValue] &&
        VDTNiceHasIndependentRule(other, VDTConfigTypeExtension, getPrefs()) &&
        !VDTListConfigurationEnabled(other, VDTConfigTypeExtension, getPrefs()));
    raw_int(entry2[VDT_NICE_VALUE_KEY], 7);

    // Host inheritance through the cached list metadata only (no bundle scan).
    NSString *inheriting = @"com.inh.ext";
    write_prefs(booleans(@[
        @[@"appConfigs", @[rec(VDTConfigTypeApp, host,
            @{VDT_NICE_ENABLED_KEY: CFBOOL(YES), VDT_NICE_VALUE_KEY: @9})]],
        @[@"extensionConfigs", @[rec(VDTConfigTypeExtension, inheriting, @{})]]]));
    VDTProcessConfiguration *owner3 = owner_for(VDTConfigTypeExtension, inheriting, meta(inheriting, host));
    VDTNicePreferences *nice3 = [owner3 vdtNicePreferences];
    NSArray *rows3 = [nice3 specifiers];
    PSSpecifier *enabled3 = nice_row(rows3, VDT_NICE_ENABLED_KEY);
    PSSpecifier *value3 = nice_row(rows3, VDT_NICE_VALUE_KEY);
    PSSpecifier *follow3 = follow_row(rows3);
    REQ("inherit.host-switch", [nice_get(nice3, enabled3) boolValue]);
    REQ("inherit.host-value", [nice_get(nice3, value3) longLongValue] == 9);
    REQ("inherit.pin-not", !VDTListConfigurationEnabled(inheriting, VDTConfigTypeExtension, getPrefs()));
    REQ("inherit.follow-state", follow3 != nil && ![[follow3 propertyForKey:@"enabled"] boolValue]);
    [owner3.specifier setProperty:meta(@"some.other.extension", host) forKey:@"vdtExtensionMetadata"];
    REQ("inherit.metadata-stale", ![nice_get(nice3, enabled3) boolValue]);
    [owner3.specifier setProperty:nil forKey:@"vdtExtensionMetadata"];
    REQ("inherit.metadata-nil", ![nice_get(nice3, value3) boolValue] &&
        [nice_get(nice3, value3) longLongValue] == 0);
}

// MARK: - real store round-trips: CFBoolean/integer on disk, snapshot isolation

static void check_store(void) {
    write_prefs(@{});
    NSString *identifier = @"com.store.ext";
    REQ("store.resource-save", setValueForProcessResourceRuleKey(identifier, @"enabled", CFBOOL(YES),
            VDTConfigTypeExtension, @"memoryRules") &&
        setValueForProcessResourceRuleKey(identifier, @"active", @64, VDTConfigTypeExtension, @"memoryRules") &&
        setValueForProcessResourceRuleKey(identifier, @"enabled", CFBOOL(YES), VDTConfigTypeExtension, @"jetsamRules") &&
        setValueForProcessResourceRuleKey(identifier, @"priority", @21, VDTConfigTypeExtension, @"jetsamRules"));
    NSDictionary *raw = read_prefs();
    NSDictionary *memory = [(raw[@"memoryRules"] ?: @[]) firstObject];
    NSDictionary *jetsam = [(raw[@"jetsamRules"] ?: @[]) firstObject];
    REQ("store.resource-shape", memory != nil && jetsam != nil);
    raw_bool(memory[@"enabled"], YES);
    raw_int(memory[@"active"], 64);
    raw_bool(jetsam[@"enabled"], YES);
    raw_int(jetsam[@"priority"], 21);
    REQ("store.pin-resource", VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, getPrefs()));

    NSMutableDictionary *seeded = [raw mutableCopy];
    seeded[@"extensionConfigs"] = @[rec(VDTConfigTypeExtension, identifier,
        @{@"enabled": CFBOOL(NO), @"percentage": @80})];
    write_prefs(seeded);
    REQ("store.nice-switch", VDTNiceSavePreference(identifier, VDTConfigTypeExtension,
        VDT_NICE_ENABLED_KEY, CFBOOL(YES), NULL));
    NSDictionary *entry = entry_in(read_prefs(), VDTConfigTypeExtension, identifier);
    raw_bool(entry[VDT_NICE_ENABLED_KEY], YES);
    raw_int(entry[VDT_NICE_VALUE_KEY], 0);
    raw_bool(entry[@"enabled"], NO);
    raw_int(entry[@"percentage"], 80);
    REQ("store.cpu-preserved", VDTListConfigurationEnabled(identifier, VDTConfigTypeExtension, getPrefs()));
    REQ("store.nice-value-save", VDTNiceSavePreference(identifier, VDTConfigTypeExtension,
        VDT_NICE_VALUE_KEY, @7, NULL));
    raw_int(entry_in(read_prefs(), VDTConfigTypeExtension, identifier)[VDT_NICE_VALUE_KEY], 7);

    NSDictionary *old = getPrefs();
    REQ("store.second-save", VDTNiceSavePreference(identifier, VDTConfigTypeExtension,
            VDT_NICE_VALUE_KEY, @9, NULL) &&
        setValueForProcessResourceRuleKey(identifier, @"active", @99, VDTConfigTypeExtension, @"memoryRules"));
    REQ("store.snapshot-old",
        [valueForProcessConfigKeyWithPrefs(identifier, VDT_NICE_VALUE_KEY, nil,
            VDTConfigTypeExtension, old) isEqual:@7] &&
        [valueForProcessResourceRuleKeyWithPrefs(identifier, @"active", nil, VDTConfigTypeExtension,
            @"memoryRules", old) isEqual:@64]);
    NSDictionary *fresh = getPrefs();
    REQ("store.snapshot-fresh",
        [valueForProcessConfigKeyWithPrefs(identifier, VDT_NICE_VALUE_KEY, nil,
            VDTConfigTypeExtension, fresh) isEqual:@9] &&
        [valueForProcessResourceRuleKeyWithPrefs(identifier, @"active", nil, VDTConfigTypeExtension,
            @"memoryRules", fresh) isEqual:@99]);
    raw_int(entry_in(fresh, VDTConfigTypeExtension, identifier)[VDT_NICE_VALUE_KEY], 9);
}

// MARK: - follow containing app nice (Extension only, CPU/resources preserved)

static void check_follow(void) {
    write_prefs(one(VDTConfigTypeApp, @"com.guard.app",
        @{@"enabled": CFBOOL(NO), VDT_NICE_ENABLED_KEY: CFBOOL(YES), VDT_NICE_VALUE_KEY: @5}));
    NSData *beforeApp = [NSData dataWithContentsOfFile:PREFS_PATH];
    unsigned beforePosts = nicePosts, beforeCf = posts;
    VDTProcessConfiguration *appOwner = owner_for(VDTConfigTypeApp, @"com.guard.app", nil);
    VDTNicePreferences *appNice = [appOwner vdtNicePreferences];
    [appNice removeIndependentNiceRule];
    REQ("follow.guard", [[NSData dataWithContentsOfFile:PREFS_PATH] isEqual:beforeApp] &&
        nicePosts == beforePosts && posts == beforeCf);

    NSString *identifier = @"com.follow.ext";
    NSMutableDictionary *seeded = [read_prefs() mutableCopy];
    seeded[@"extensionConfigs"] = @[rec(VDTConfigTypeExtension, identifier,
        @{@"enabled": CFBOOL(NO), @"percentage": @80, VDT_NICE_ENABLED_KEY: CFBOOL(YES),
          VDT_NICE_VALUE_KEY: @5, VDT_NICE_REVISION_KEY: @"rev-1"})];
    write_prefs(seeded);
    REQ("follow.seed", setValueForProcessResourceRuleKey(identifier, @"enabled", CFBOOL(YES),
            VDTConfigTypeExtension, @"memoryRules") &&
        setValueForProcessResourceRuleKey(identifier, @"active", @64, VDTConfigTypeExtension, @"memoryRules"));
    VDTProcessConfiguration *owner = owner_for(VDTConfigTypeExtension, identifier,
        meta(identifier, @"com.follow.host"));
    PSListController *parent = [PSListController new];
    [owner setValue:parent forKey:@"_parentController"];
    VDTNicePreferences *nice = [owner vdtNicePreferences];
    REQ("follow.rows", nice_row([nice specifiers], VDT_NICE_ENABLED_KEY) != nil);

    unsigned postsBefore = nicePosts;
    [nice confirmFollowContainingAppNice];
    REQ("follow.alert", owner.lastAlert != nil && owner.lastAlert.actions.count == 2 &&
        owner.lastAlert.actions.lastObject.handler != nil);
    owner.lastAlert.actions.lastObject.handler(owner.lastAlert.actions.lastObject);
    NSDictionary *raw = read_prefs();
    NSDictionary *entry = entry_in(raw, VDTConfigTypeExtension, identifier);
    NSDictionary *memory = [(raw[@"memoryRules"] ?: @[]) firstObject];
    REQ("follow.fields", entry != nil && !nice_fields_present(entry) &&
        entry[@"enabled"] != nil && CFEqual((__bridge CFTypeRef)entry[@"enabled"], kCFBooleanFalse) &&
        [entry[@"percentage"] isEqual:@80]);
    REQ("follow.fields-resource", memory != nil && [memory[@"enabled"] boolValue] && [memory[@"active"] isEqual:@64]);
    REQ("follow.notify", nicePosts == postsBefore + 1);
    REQ("follow.parent-reload", parent.reloadSpecifiersCount == 1);
    unsigned afterRemove = nicePosts;
    [nice removeIndependentNiceRule];
    REQ("follow.idempotent", nicePosts == afterRemove && !nice_fields_present(
        entry_in(read_prefs(), VDTConfigTypeExtension, identifier)));
}

// MARK: - explicit type guard: three legal types, unknown type rejected

static void check_owner_guard(void) {
    const VDTConfigType types[] = {VDTConfigTypeApp, VDTConfigTypeDaemon, VDTConfigTypeExtension};
    const char *names[] = {"app", "daemon", "extension"};
    for (int i = 0; i < 3; ++i) {
        NSString *identifier = [NSString stringWithFormat:@"com.guard.%s", names[i]];
        VDTProcessConfiguration *owner = owner_for(types[i], identifier, nil);
        NSUInteger niceRows = 0;
        for (PSSpecifier *specifier in [owner specifiers])
            if ([[specifier propertyForKey:@"key"] isEqual:VDT_NICE_ENABLED_KEY]) ++niceRows;
        NSString *tag = [NSString stringWithFormat:@"guard.three-types.%s", names[i]];
        REQ(tag.UTF8String, niceRows == 1 && [owner valueForKey:@"_nicePreferences"] != nil);
    }
    VDTProcessConfiguration *bad = owner_for((VDTConfigType)999, @"com.guard.bad", nil);
    NSUInteger niceRows = 0;
    for (PSSpecifier *specifier in [bad specifiers])
        if ([[specifier propertyForKey:@"key"] isEqual:VDT_NICE_ENABLED_KEY]) ++niceRows;
    REQ("guard.reject-999", niceRows == 0 && [bad valueForKey:@"_nicePreferences"] == nil);
}

// MARK: - CPU Follow keeps nice/resource fields (Extension CPU-only removal)

static void check_cpu_follow(void) {
    NSString *identifier = @"com.cpufollow.ext";
    write_prefs(booleans(@[
        @[@"extensionConfigs", @[rec(VDTConfigTypeExtension, identifier,
            @{@"enabled": CFBOOL(NO), @"percentage": @80, VDT_NICE_ENABLED_KEY: CFBOOL(YES),
              VDT_NICE_VALUE_KEY: @5})]],
        @[@"memoryRules", @[rec(VDTConfigTypeExtension, identifier, @{@"enabled": CFBOOL(YES)})]],
        @[@"jetsamRules", @[rec(VDTConfigTypeExtension, identifier, @{@"priority": @21})]]]));
    unsigned notifications = nicePosts + posts;
    VDTRemoveProcessConfig(identifier, VDTConfigTypeExtension);
    NSDictionary *raw = read_prefs();
    NSDictionary *entry = entry_in(raw, VDTConfigTypeExtension, identifier);
    NSDictionary *memory = [(raw[@"memoryRules"] ?: @[]) firstObject];
    NSDictionary *jetsam = [(raw[@"jetsamRules"] ?: @[]) firstObject];
    REQ("cpufollow.fields", entry != nil && entry[@"enabled"] == nil && entry[@"percentage"] == nil &&
        [entry[VDT_NICE_ENABLED_KEY] boolValue] && [entry[VDT_NICE_VALUE_KEY] isEqual:@5]);
    REQ("cpufollow.resources", memory != nil && jetsam != nil &&
        [memory[@"enabled"] boolValue] && [jetsam[@"priority"] isEqual:@21]);
    REQ("cpufollow.notify", nicePosts + posts == notifications + 1);
    VDTRemoveProcessConfig(identifier, VDTConfigTypeExtension);
    REQ("cpufollow.idempotent", entry_in(read_prefs(), VDTConfigTypeExtension, identifier) != nil);
    // A real malformed file must never be replaced by an empty dictionary or
    // broadcast as a successful CPU Follow operation.
    NSData *malformed = [@"not-a-plist" dataUsingEncoding:NSUTF8StringEncoding];
    REQ("cpufollow.badfile-write", [malformed writeToFile:PREFS_PATH atomically:YES]);
    unsigned beforeBadPosts = posts + nicePosts;
    REQ("cpufollow.badfile-rejected", !VDTRemoveExtensionCPUConfigReportingResult(identifier));
    REQ("cpufollow.badfile-preserved", [[NSData dataWithContentsOfFile:PREFS_PATH] isEqual:malformed] &&
        beforeBadPosts == posts + nicePosts);
    write_prefs(@{});
}

int main(void) {
    @autoreleasepool {
        gRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"vdt-independent-rules-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        REQ("fixture.root", [[NSFileManager defaultManager] createDirectoryAtPath:gRoot
            withIntermediateDirectories:YES attributes:nil error:&error] || error == nil);
        write_prefs(@{});
        check_pins();
        VDTProcessConfiguration *mixedOwner = owner_for(VDTConfigTypeExtension, @"com.mixed.ext", nil);
        VDTNicePreferences *mixedNice = [mixedOwner vdtNicePreferences];
        PSSpecifier *mixedEnabled = nice_row([mixedNice specifiers], VDT_NICE_ENABLED_KEY);
        REQ("mixed.rows", mixedEnabled != nil);
        check_mixed_duplicates(mixedOwner, mixedNice, mixedEnabled);
        check_subtitles();
        check_grouping();
        check_nice_ui();
        check_store();
        check_follow();
        check_cpu_follow();
        check_owner_guard();
        printf("NATIVE OK: pins/mixed/subtitles/group/nice/store/follow/guard\n");
    }
    return 0;
}
