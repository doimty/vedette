//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "VDTProbe.h"
#import "PrivateHeaders.h"
#import "VDTProcessIdentity.h"
#import "VDTPolicyTransition.h"
#import "VDTSpringBoardIdentity.h"
#import "VDTBundleIdentity.h"
#import "VDTBundleRules.h"
#import "VDTResourceApply.h"
#import "VDTNiceShared.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <os/lock.h>
#include <stdlib.h>

#pragma mark - Thread-safe prefs storage

static NSDictionary *_prefs;
static os_unfair_lock _prefsLock = OS_UNFAIR_LOCK_INIT;

void VDTSetPrefs(NSDictionary *newPrefs){
    os_unfair_lock_lock(&_prefsLock);
    _prefs = newPrefs;
    os_unfair_lock_unlock(&_prefsLock);
}

NSDictionary *VDTGetPrefs(void){
    os_unfair_lock_lock(&_prefsLock);
    NSDictionary *snapshot = _prefs;
    os_unfair_lock_unlock(&_prefsLock);
    return snapshot;
}

#pragma mark - Untrusted plist accessors
//
// The prefs plist is user-writable and can be hand-edited or partially written.
// Every read below is type-checked: an unexpected type must never reach an
// Objective-C selector or a collection literal, because this code runs inside
// runningboardd and an uncaught exception there takes the process down.

static NSArray *vdt_array(id value){
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
}

static NSDictionary *vdt_dictionary(id value){
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSString *vdt_nonEmptyString(id value){
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = (NSString *)value;
    return string.length > 0 ? string : nil;
}

static NSNumber *vdt_number(id value){
    return [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
}

static BOOL vdt_int(id value, int defaultValue, int *outValue){
    if (!outValue) return NO;
    if (!value) {
        *outValue = defaultValue;
        return YES;
    }

    long long parsed = 0;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;

        double numericValue = number.doubleValue;
        parsed = number.longLongValue;
        if (!isfinite(numericValue) || numericValue != (double)parsed) return NO;
    } else if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd) return NO;
    } else {
        return NO;
    }

    if (parsed < INT_MIN || parsed > INT_MAX) return NO;
    *outValue = (int)parsed;
    return YES;
}

static BOOL vdt_bool(id value, BOOL defaultValue){
    if (!value) return defaultValue;
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    return [(NSNumber *)value boolValue];
}

static BOOL vdt_policy(id value, VDTViolationPolicy *outPolicy){
    if (!outPolicy) return NO;
    if (!value) {
        *outPolicy = VDTViolationPolicyMonitorAndTerminate;
        return YES;
    }

    int raw = 0;
    if (!vdt_int(value, 0, &raw)) return NO;
    switch ((VDTViolationPolicy)raw) {
        case VDTViolationPolicyMonitorAndTerminate:
        case VDTViolationPolicyThrottle:
            *outPolicy = (VDTViolationPolicy)raw;
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Process helpers

static LSApplicationProxy* appproxy_from_bundle_path(NSString *path){
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;

    NSURL *bundleURL = nil;
    @try {
        bundleURL = [NSURL fileURLWithPath:path];
    } @catch (NSException *exception) {
        HBLogError(@"Vedette: NSURL exception for path %@: %@ %@", path, exception.name, exception.reason);
        return nil;
    }
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!bundleURL || ![proxyClass respondsToSelector:@selector(applicationProxyForBundleURL:)]) return nil;

    return [proxyClass applicationProxyForBundleURL:bundleURL];
}

static NSString *application_bundle_path_for_executable(NSString *executablePath){
    if (![executablePath isKindOfClass:[NSString class]] || executablePath.length == 0) return nil;

    NSString *candidate = executablePath.stringByDeletingLastPathComponent;
    while (candidate.length > 1) {
        if ([candidate.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame) return candidate;
        NSString *parent = candidate.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:candidate]) break;
        candidate = parent;
    }
    return nil;
}

// Full executable path. Empty string when unavailable, never partial data.
static BOOL executable_path_for_pid(pid_t pid, char *buffer, uint32_t bufferSize){
    return VDTCopyProcessInfoString(pid, buffer, bufferSize, proc_pidpath);
}

// proc_name returns the kernel's possibly truncated p_comm. It is only an exact-
// match fallback when the full executable path is unavailable.
static BOOL proc_comm_for_pid(pid_t pid, char *out, uint32_t outSize){
    return VDTCopyProcessInfoString(pid, out, outSize, proc_name);
}

static BOOL process_instance_token_for_pid(pid_t pid, VDTProcessInstanceToken *outToken){
    if (pid <= 0 || !outToken) return NO;

    struct vdt_proc_bsdinfo info = {};
    int bytes = proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != (int)sizeof(info) || info.pbi_pid != (uint32_t)pid) return NO;

    VDTProcessInstanceToken token = {
        .seconds = info.pbi_start_tvsec,
        .microseconds = info.pbi_start_tvusec
    };
    if (!VDTProcessInstanceTokenIsValid(token)) return NO;

    *outToken = token;
    return YES;
}

#pragma mark - Config normalisation

NSString * const VDTConfigIdentifierKey = @"identifier";
NSString * const VDTConfigTypeKey = @"type";
NSString * const VDTConfigPercentageKey = @"percentage";
NSString * const VDTConfigIntervalKey = @"interval";
NSString * const VDTConfigPolicyKey = @"policy";
NSString * const VDTConfigEnabledKey = @"enabled";
NSString * const VDTTargetPidKey = @"pid";
NSString * const VDTTargetNameKey = @"name";
NSString * const VDTTargetExecutablePathKey = @"executablePath";
NSString * const VDTTargetProcCommKey = @"procComm";
NSString * const VDTTargetStartSecondsKey = @"startSeconds";
NSString * const VDTTargetStartMicrosecondsKey = @"startMicroseconds";
NSString * const VDTTargetMemoryRuleKey = @"memoryRule";
NSString * const VDTTargetJetsamRuleKey = @"jetsamRule";
NSString * const VDTTargetContainingAppIdentifierKey = @"containingAppIdentifier";
NSString * const VDTTargetNiceSourceTypeKey = @"niceSourceType";
NSString * const VDTTargetNiceSourceIdentifierKey = @"niceSourceIdentifier";
NSString * const VDTTargetNiceSourceRevisionKey = @"niceSourceRevision";

static NSArray<NSDictionary *> *configs_from_section(NSDictionary *prefs,
                                                     NSString *sectionKey,
                                                     NSString *identifierKey,
                                                     VDTConfigType type,
                                                     BOOL globallyEnabled){
    NSMutableArray<NSDictionary *> *configs = [NSMutableArray array];
    NSArray *section = vdt_array(prefs[sectionKey]);

    for (id rawEntry in section) {
        NSDictionary *entry = vdt_dictionary(rawEntry);
        if (!entry) continue;
        // Nice-only/unknown-only rows must not suppress the containing App CPU rule.
        if (type == VDTConfigTypeExtension && !VDTProcessConfigHasCPUFields(entry)) continue;

        NSString *identifier = vdt_nonEmptyString(entry[identifierKey]);
        if (!identifier) continue;

        // The Settings app hosts the preference bundle itself; throttling it
        // would lock the user out of their own configuration.
        if (type == VDTConfigTypeApp && [identifier isEqualToString:@"com.apple.Preferences"]) continue;

        int percentage = 0;
        int interval = 0;
        VDTViolationPolicy policy = VDTViolationPolicyNone;
        BOOL percentageValid = vdt_int(entry[@"percentage"], 80, &percentage);
        BOOL intervalValid = vdt_int(entry[@"interval"], 120, &interval);
        BOOL policyValid = vdt_policy(entry[@"violationPolicy"], &policy);
        BOOL percentageInRange = policy == VDTViolationPolicyThrottle ?
            percentage <= UINT8_MAX : percentage <= 100;
        BOOL parametersValid = percentageValid && percentage > 0 && percentageInRange &&
            policyValid && (policy == VDTViolationPolicyThrottle ||
            (intervalValid && interval > 0));
        BOOL enabled = globallyEnabled && vdt_bool(entry[@"enabled"], NO) && parametersValid;

        [configs addObject:@{
            VDTConfigIdentifierKey: identifier,
            VDTConfigTypeKey: @(type),
            VDTConfigPercentageKey: @(percentageValid ? percentage : 0),
            VDTConfigIntervalKey: @(intervalValid ? interval : 0),
            VDTConfigPolicyKey: @(policyValid ? policy : VDTViolationPolicyNone),
            // Missing values use the preference UI's defaults. Explicitly empty,
            // malformed or non-positive values fail closed instead of turning
            // into an implicit fatal monitor.
            VDTConfigEnabledKey: @(enabled)
        }];
    }

    return configs;
}

NSArray<NSDictionary *>* vdt_configs_from_prefs(NSDictionary *prefs){
    NSDictionary *validatedPrefs = vdt_dictionary(prefs);
    if (!validatedPrefs) return @[];

    BOOL globallyEnabled = vdt_bool(validatedPrefs[@"enabled"], YES);

    NSMutableArray<NSDictionary *> *configs = [NSMutableArray array];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"appConfigs", @"bundleIdentifier",
                                                     VDTConfigTypeApp, globallyEnabled)];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"daemonConfigs", @"daemonName",
                                                     VDTConfigTypeDaemon, globallyEnabled)];
    [configs addObjectsFromArray:configs_from_section(validatedPrefs, @"extensionConfigs", @"extensionIdentifier",
                                                     VDTConfigTypeExtension, globallyEnabled)];
    return configs;
}

#pragma mark - Resource rules (memoryRules / jetsamRules)

// The Jetsam policy cores are versioned by Darwin major; iOS 15–18 map to
// Darwin 21–24. Unknown future versions resolve to a read-only plan.
static int32_t vdt_target_darwin_major(void){
    return (int32_t)(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion + 6);
}

// Classify an untrusted plist value exactly the way the C cores expect. A
// CFBoolean or a non-integral number must never be coerced into an integer.
static VDTPolicyInteger resource_policy_integer(id value){
    if (!value) return (VDTPolicyInteger){VDTPolicyInputNull, 0};
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
            return (VDTPolicyInteger){VDTPolicyInputBoolean, 0};
        }
        double numericValue = number.doubleValue;
        long long integralValue = number.longLongValue;
        if (!isfinite(numericValue)) return (VDTPolicyInteger){VDTPolicyInputOverflow, 0};
        if (numericValue != (double)integralValue) {
            return (VDTPolicyInteger){VDTPolicyInputFloatingPoint, 0};
        }
        return (VDTPolicyInteger){VDTPolicyInputInteger, integralValue};
    }
    if ([value isKindOfClass:[NSString class]]) return (VDTPolicyInteger){VDTPolicyInputString, 0};
    return (VDTPolicyInteger){VDTPolicyInputInvalid, 0};
}

static BOOL resource_rule_enabled_value(id value, BOOL *outEnabled){
    if (!outEnabled) return NO;
    if (!value) {
        *outEnabled = NO;
        return YES;
    }
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    *outEnabled = [(NSNumber *)value boolValue];
    return YES;
}

// Builds the typed core input for one stored record. Load time and apply time
// share these builders, so classification and planning can never disagree.
static VDTMemoryRule resource_memory_core_rule(NSDictionary *rule, VDTPolicyRecordState state){
    VDTMemoryRuleInput input = {
        .state = state,
        .schema = resource_policy_integer(rule[@"schema"]),
        .active = resource_policy_integer(rule[@"active"]),
        .inactive = resource_policy_integer(rule[@"inactive"])
    };
    return VDTParseMemoryRule(&input);
}

static VDTJetsamRule resource_jetsam_core_rule(NSDictionary *rule, VDTPolicyRecordState state){
    VDTJetsamRuleInput input = {
        .state = state,
        .schema = resource_policy_integer(rule[@"schema"]),
        .mode = VDTJetsamModeRaw,
        .named = VDTJetsamNamedInvalid,
        .rawBand = resource_policy_integer(rule[@"priority"]),
        // The saved band is owned by the device that wrote it: a later OS
        // upgrade turns the source major into a mismatch the core refuses
        // instead of silently migrating the number.
        .rawSourceDarwinMajor = resource_policy_integer(@(vdt_target_darwin_major()))
    };
    return VDTParseJetsamRule(&input);
}

// One normalised resource rule. `state` mirrors the frozen cores: presence —
// including a disabled or malformed record — overrides host inheritance.
static NSDictionary *resource_rule_from_entry(NSDictionary *validatedEntry,
                                              NSString *sectionKey,
                                              NSString *identifierKey,
                                              VDTConfigType type,
                                              BOOL globallyEnabled){
    NSString *identifier = vdt_nonEmptyString(validatedEntry[identifierKey]);
    if (!identifier) return nil;

    BOOL enabled = NO;
    BOOL enabledValid = resource_rule_enabled_value(validatedEntry[@"enabled"], &enabled);
    VDTPolicyRecordState state = VDTPolicyRecordInvalid;
    if (enabledValid && (!enabled || !globallyEnabled)) {
        // The member switch folds into "disabled" exactly like the CPU rows;
        // the record still overrides inheritance so a reload can undo it.
        state = VDTPolicyRecordDisabled;
    } else if (enabledValid) {
        BOOL memorySection = [sectionKey isEqualToString:@"memoryRules"];
        VDTPolicyParseStatus parseStatus = memorySection ?
            resource_memory_core_rule(validatedEntry, VDTPolicyRecordEnabled).parseStatus :
            resource_jetsam_core_rule(validatedEntry, VDTPolicyRecordEnabled).parseStatus;
        if (parseStatus == VDTPolicyParseOK) state = VDTPolicyRecordEnabled;
    }

    NSMutableDictionary *rule = [@{
        VDTConfigIdentifierKey: identifier,
        VDTConfigTypeKey: @(type),
        @"section": sectionKey,
        @"state": @(state),
        VDTConfigEnabledKey: @(state == VDTPolicyRecordEnabled)
    } mutableCopy];
    for (NSString *key in @[@"schema", @"active", @"inactive", @"priority"]) {
        if (validatedEntry[key]) rule[key] = validatedEntry[key];
    }
    return rule;
}

static NSArray<NSDictionary *> *resource_rules_from_section(NSDictionary *validatedPrefs,
                                                            NSString *sectionKey,
                                                            NSString *identifierKey,
                                                            VDTConfigType type,
                                                            BOOL globallyEnabled){
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    for (id rawEntry in vdt_array(validatedPrefs[sectionKey])) {
        NSDictionary *entry = vdt_dictionary(rawEntry);
        if (!entry) continue;
        NSDictionary *rule = resource_rule_from_entry(entry, sectionKey, identifierKey, type, globallyEnabled);
        if (rule) [rules addObject:rule];
    }
    return rules;
}

NSArray<NSDictionary *>* vdt_resource_rules_from_prefs(NSDictionary *prefs){
    NSDictionary *validatedPrefs = vdt_dictionary(prefs);
    if (!validatedPrefs) return @[];

    BOOL globallyEnabled = vdt_bool(validatedPrefs[@"enabled"], YES);
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    for (NSString *sectionKey in @[@"memoryRules", @"jetsamRules"]) {
        [rules addObjectsFromArray:resource_rules_from_section(validatedPrefs, sectionKey,
            @"bundleIdentifier", VDTConfigTypeApp, globallyEnabled)];
        [rules addObjectsFromArray:resource_rules_from_section(validatedPrefs, sectionKey,
            @"daemonName", VDTConfigTypeDaemon, globallyEnabled)];
        [rules addObjectsFromArray:resource_rules_from_section(validatedPrefs, sectionKey,
            @"extensionIdentifier", VDTConfigTypeExtension, globallyEnabled)];
    }
    return rules;
}

// Per-resource rule index. App and extension records are keyed by identifier;
// daemon records stay a list because they match by executable name.
typedef struct VDTResourceRuleMaps {
    NSMutableDictionary<NSString *, NSDictionary *> *appMemoryById;
    NSMutableDictionary<NSString *, NSDictionary *> *extensionMemoryById;
    NSMutableDictionary<NSString *, NSDictionary *> *appJetsamById;
    NSMutableDictionary<NSString *, NSDictionary *> *extensionJetsamById;
    NSMutableArray<NSDictionary *> *daemonMemory;
    NSMutableArray<NSDictionary *> *daemonJetsam;
} VDTResourceRuleMaps;

static VDTResourceRuleMaps resource_rule_maps(NSArray<NSDictionary *> *rules){
    VDTResourceRuleMaps maps = {};
    maps.appMemoryById = [NSMutableDictionary dictionary];
    maps.extensionMemoryById = [NSMutableDictionary dictionary];
    maps.appJetsamById = [NSMutableDictionary dictionary];
    maps.extensionJetsamById = [NSMutableDictionary dictionary];
    maps.daemonMemory = [NSMutableArray array];
    maps.daemonJetsam = [NSMutableArray array];

    for (id rawRule in rules) {
        NSDictionary *rule = vdt_dictionary(rawRule);
        if (!rule) continue;
        NSString *identifier = vdt_nonEmptyString(rule[VDTConfigIdentifierKey]);
        NSNumber *typeValue = vdt_number(rule[VDTConfigTypeKey]);
        NSString *sectionKey = vdt_nonEmptyString(rule[@"section"]);
        if (!identifier || !typeValue || !sectionKey) continue;

        BOOL memory = [sectionKey isEqualToString:@"memoryRules"];
        VDTConfigType type = (VDTConfigType)typeValue.unsignedLongValue;
        if (type == VDTConfigTypeApp) {
            NSMutableDictionary *map = memory ? maps.appMemoryById : maps.appJetsamById;
            // First entry wins, matching the preference API and the CPU path.
            if (!map[identifier]) map[identifier] = rule;
        } else if (type == VDTConfigTypeExtension) {
            NSMutableDictionary *map = memory ? maps.extensionMemoryById : maps.extensionJetsamById;
            if (!map[identifier]) map[identifier] = rule;
        } else if (type == VDTConfigTypeDaemon) {
            [(memory ? maps.daemonMemory : maps.daemonJetsam) addObject:rule];
        }
    }
    return maps;
}

static BOOL resource_maps_empty(VDTResourceRuleMaps maps){
    return maps.appMemoryById.count == 0 && maps.extensionMemoryById.count == 0 &&
        maps.appJetsamById.count == 0 && maps.extensionJetsamById.count == 0 &&
        maps.daemonMemory.count == 0 && maps.daemonJetsam.count == 0;
}

// Presence, not enabled state, decides inheritance: an extension record of any
// state overrides the containing App; a missing record inherits its records.
static NSDictionary *resource_rule_for_extension(NSString *extensionIdentifier,
                                                 NSString *appIdentifier,
                                                 NSDictionary<NSString *, NSDictionary *> *extensionRulesById,
                                                 NSDictionary<NSString *, NSDictionary *> *appRulesById){
    if (!extensionIdentifier) return nil;
    NSDictionary *extensionRule = extensionRulesById[extensionIdentifier];
    if (extensionRule) return extensionRule;
    return appIdentifier ? appRulesById[appIdentifier] : nil;
}

static NSDictionary *resource_rule_for_daemon(NSArray<NSDictionary *> *daemonRules,
                                              const char *executableName,
                                              const char *procComm,
                                              const char *executablePath){
    for (NSDictionary *rule in daemonRules) {
        NSString *configuredName = vdt_nonEmptyString(rule[VDTConfigIdentifierKey]);
        if (!configuredName) continue;
        const char *configured = configuredName.UTF8String;
        if (!configured) continue;
        // The same reserved identity applies to every resource; a basename
        // or p_comm called SpringBoard is never proof of the system process.
        if (VDTSpringBoardRuleName(configured)) {
            if (VDTSpringBoardRuleMatches(configured, executablePath)) return rule;
            continue;
        }
        if (VDTProcessNameMatches(configured, executableName, procComm)) return rule;
    }
    return nil;
}

#pragma mark - Target resolution

static void split_configs(NSArray<NSDictionary *> *configs,
                         NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById,
                         NSMutableDictionary<NSString *, NSDictionary *> *extensionConfigsById,
                         NSMutableArray<NSDictionary *> *daemonConfigs){
    for (id rawConfig in configs) {
        NSDictionary *config = vdt_dictionary(rawConfig);
        NSString *identifier = vdt_nonEmptyString(config[VDTConfigIdentifierKey]);
        NSNumber *typeValue = vdt_number(config[VDTConfigTypeKey]);
        if (!identifier || !typeValue) continue;

        VDTConfigType type = (VDTConfigType)typeValue.unsignedLongValue;
        if (type == VDTConfigTypeApp) {
            // Preserve the preference API's first-entry-wins behavior if a
            // hand-edited plist contains duplicate identifiers.
            if (!appConfigsById[identifier]) appConfigsById[identifier] = config;
        } else if (type == VDTConfigTypeExtension) {
            // Presence, including a disabled/malformed first entry, overrides
            // the containing App without sharing its identifier namespace.
            if (!extensionConfigsById[identifier]) extensionConfigsById[identifier] = config;
        } else if (type == VDTConfigTypeDaemon) {
            [daemonConfigs addObject:config];
        }
    }
}

// Resolves one PID against the configured set. Returns nil when the process is
// not configured, which is the signal to leave it completely alone.
static NSDictionary *target_for_pid(pid_t pid,
                                    NSDictionary<NSString *, NSDictionary *> *appConfigsById,
                                    NSDictionary<NSString *, NSDictionary *> *extensionConfigsById,
                                    NSArray<NSDictionary *> *daemonConfigs,
                                    VDTResourceRuleMaps resourceMaps){
    if (pid <= 0) return nil;

    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    BOOL hasExecutablePath = executable_path_for_pid(pid, pathBuffer, sizeof(pathBuffer));
    NSString *executablePath = hasExecutablePath ? [NSString stringWithUTF8String:pathBuffer] : nil;
    if (executablePath.length == 0) executablePath = nil;

    char executableName[PROC_PIDPATHINFO_MAXSIZE];
    BOOL hasExecutableName = hasExecutablePath &&
        VDTCopyLastPathComponent(pathBuffer, executableName, sizeof(executableName));

    VDTProcessInstanceToken instanceToken = {};
    if (!process_instance_token_for_pid(pid, &instanceToken)) return nil;

    NSDictionary *matched = nil;
    NSString *matchedName = nil;
    NSString *fallbackProcComm = nil;

    // Only the canonical system executable may use this reserved daemon rule.
    // Explicit SpringBoard entries win (including disabled entries), so a
    // separately hand-written App rule cannot silently re-enable that target.
    if (VDTSpringBoardPathMatches(executablePath.UTF8String)) {
        for (NSDictionary *config in daemonConfigs) {
            NSString *identifier = vdt_nonEmptyString(config[VDTConfigIdentifierKey]);
            if (VDTSpringBoardRuleMatches(identifier.UTF8String, executablePath.UTF8String)) {
                matched = config;
                matchedName = identifier;
                break;
            }
        }
    }

    // Validate the nearest extension before considering its containing App.
    // An explicit extension entry wins by presence, not by enabled state;
    // invalid extension metadata must never inherit an App or daemon rule.
    NSString *extensionPath = VDTNearestBundlePath(executablePath, @"appex");
    if (!extensionPath && executablePath) {
        // A rejected/noncanonical appex path must not masquerade as its App
        // after the strict path classifier declines it. This is a blocker,
        // never an alternate source of extension identity or metadata.
        NSString *candidate = executablePath.stringByDeletingLastPathComponent;
        while (candidate.length > 1) {
            if ([candidate.pathExtension caseInsensitiveCompare:@"appex"] == NSOrderedSame) return nil;
            NSString *parent = candidate.stringByDeletingLastPathComponent;
            if ([parent isEqualToString:candidate]) break;
            candidate = parent;
        }
    }
    NSDictionary *extensionInfo = extensionPath ?
        VDTReadExtensionBundleInfo(extensionPath, executablePath) : nil;
    NSString *extensionIdentifier = vdt_nonEmptyString(extensionInfo[@"extensionIdentifier"]);
    NSDictionary *extensionConfig = extensionIdentifier ? extensionConfigsById[extensionIdentifier] : nil;

    // Keep the release App ancestry check: even an unconfigured .app must
    // never fall through to an unrelated basename/p_comm daemon rule.
    NSString *bundlePath = application_bundle_path_for_executable(extensionPath ?: executablePath);
    NSString *bundleIdentifier = nil;
    NSDictionary *appConfig = nil;
    if (!matched && bundlePath && appConfigsById.count > 0 &&
        (!extensionPath || (extensionIdentifier && !extensionConfig))) {
        LSApplicationProxy *appProxy = appproxy_from_bundle_path(bundlePath);
        bundleIdentifier = vdt_nonEmptyString(appProxy.bundleIdentifier);
        if (bundleIdentifier) appConfig = appConfigsById[bundleIdentifier];
    }

    VDTBundleRuleChoice ruleChoice = matched ? VDTBundleRuleNone :
        VDTChooseBundleRule(bundlePath != nil, extensionPath != nil,
        extensionIdentifier != nil, extensionConfig != nil, appConfig != nil);
    if (ruleChoice == VDTBundleRuleExtension) {
        matched = extensionConfig;
        matchedName = extensionIdentifier;
    } else if (ruleChoice == VDTBundleRuleApp) {
        matched = appConfig;
        matchedName = bundleIdentifier;
    }

    if (ruleChoice == VDTBundleRuleDaemon && daemonConfigs.count > 0) {
        char procComm[256];
        BOOL hasProcComm = !hasExecutableName && proc_comm_for_pid(pid, procComm, sizeof(procComm));
        if (!hasExecutableName && !hasProcComm) return nil;
        if (hasProcComm) {
            fallbackProcComm = [NSString stringWithUTF8String:procComm];
            if (fallbackProcComm.length == 0) return nil;
        }

        for (NSDictionary *config in daemonConfigs) {
            NSString *configuredName = config[VDTConfigIdentifierKey];
            const char *configured = configuredName.UTF8String;
            // Never fall back to basename/p_comm for the reserved system rule.
            if (!configured || VDTSpringBoardRuleName(configured)) continue;
            if (VDTProcessNameMatches(configured,
                                      hasExecutableName ? executableName : NULL,
                                      hasProcComm ? procComm : NULL)) {
                matched = config;
                matchedName = configuredName;
                break;
            }
        }
    }

    // Resource rules resolve on the same validated identity and travel with
    // the target independently of the CPU decision. The per-resource presence
    // rule applies: a record of any state overrides host inheritance, while a
    // missing record inherits the containing App's record for that resource.
    NSDictionary *memoryRule = nil;
    NSDictionary *jetsamRule = nil;
    NSNumber *resourceIdentityType = nil;
    NSString *resourceIdentityName = nil;
    // Each resource has its own explicit reserved-daemon override. Presence
    // wins even when disabled/invalid, without changing the CPU/nice choice.
    if (VDTSpringBoardPathMatches(executablePath.UTF8String)) {
        memoryRule = resource_rule_for_daemon(resourceMaps.daemonMemory, NULL, NULL,
            executablePath.UTF8String);
        jetsamRule = resource_rule_for_daemon(resourceMaps.daemonJetsam, NULL, NULL,
            executablePath.UTF8String);
        if (memoryRule || jetsamRule) {
            resourceIdentityType = @(VDTConfigTypeDaemon);
            resourceIdentityName = @VDT_SPRINGBOARD_RULE_NAME;
        }
    }

    BOOL resourceNeedsApp = (!memoryRule && resourceMaps.appMemoryById.count > 0) ||
        (!jetsamRule && resourceMaps.appJetsamById.count > 0);
    NSString *resourceBundleIdentifier = bundleIdentifier;
    // Failed extension verification is authoritative for ALL resources, not
    // an invitation to inherit the containing App or a same-name daemon.
    if (!resourceBundleIdentifier && bundlePath && resourceNeedsApp &&
        (!extensionPath || extensionIdentifier)) {
        LSApplicationProxy *resourceProxy = appproxy_from_bundle_path(bundlePath);
        resourceBundleIdentifier = vdt_nonEmptyString(resourceProxy.bundleIdentifier);
    }

    if (extensionIdentifier) {
        memoryRule = resource_rule_for_extension(extensionIdentifier, resourceBundleIdentifier,
            resourceMaps.extensionMemoryById, resourceMaps.appMemoryById);
        jetsamRule = resource_rule_for_extension(extensionIdentifier, resourceBundleIdentifier,
            resourceMaps.extensionJetsamById, resourceMaps.appJetsamById);
        resourceIdentityType = @(VDTConfigTypeExtension);
        resourceIdentityName = extensionIdentifier;
    } else if (!extensionPath && resourceBundleIdentifier) {
        if (!memoryRule) memoryRule = resourceMaps.appMemoryById[resourceBundleIdentifier];
        if (!jetsamRule) jetsamRule = resourceMaps.appJetsamById[resourceBundleIdentifier];
        if (!resourceIdentityType && (memoryRule || jetsamRule)) {
            resourceIdentityType = @(VDTConfigTypeApp);
            resourceIdentityName = resourceBundleIdentifier;
        }
    } else if (!extensionPath && !bundlePath &&
               (resourceMaps.daemonMemory.count > 0 || resourceMaps.daemonJetsam.count > 0)) {
        const char *resourceComm = fallbackProcComm.UTF8String;
        char resourceProcComm[256];
        if (!hasExecutableName && !resourceComm &&
            proc_comm_for_pid(pid, resourceProcComm, sizeof(resourceProcComm))) {
            NSString *comm = [NSString stringWithUTF8String:resourceProcComm];
            if (comm.length > 0) {
                fallbackProcComm = comm;
                resourceComm = fallbackProcComm.UTF8String;
            }
        }
        // Resource identity lookup failure leaves any CPU target intact.
        if (hasExecutableName || resourceComm) {
            memoryRule = resource_rule_for_daemon(resourceMaps.daemonMemory,
                hasExecutableName ? executableName : NULL, resourceComm, executablePath.UTF8String);
            jetsamRule = resource_rule_for_daemon(resourceMaps.daemonJetsam,
                hasExecutableName ? executableName : NULL, resourceComm, executablePath.UTF8String);
            if (memoryRule || jetsamRule) {
                resourceIdentityType = @(VDTConfigTypeDaemon);
                resourceIdentityName = (memoryRule ?: jetsamRule)[VDTConfigIdentifierKey];
            }
        }
    }
    BOOL hasResourceIntent = memoryRule != nil || jetsamRule != nil;

    if (!matched && !hasResourceIntent) return nil;

    NSNumber *typeValue = vdt_number(matched[VDTConfigTypeKey]);
    NSNumber *enabledValue = vdt_number(matched[VDTConfigEnabledKey]);
    if (!typeValue || !enabledValue) {
        // Resource-only target: the CPU side stays disabled, but the validated
        // identity still owns the resource intents for this instance.
        if (matched || !hasResourceIntent || !resourceIdentityType) return nil;
        typeValue = resourceIdentityType;
        enabledValue = @NO;
    }

    BOOL enabled = enabledValue.boolValue;
    NSNumber *percentage = enabled ? vdt_number(matched[VDTConfigPercentageKey]) : @0;
    NSNumber *interval = enabled ? vdt_number(matched[VDTConfigIntervalKey]) : @0;
    NSNumber *policy = enabled ? vdt_number(matched[VDTConfigPolicyKey]) : @(VDTViolationPolicyNone);
    if (!percentage || !interval || !policy) return nil;

    NSMutableDictionary *target = [@{
        VDTTargetPidKey: @(pid),
        VDTTargetNameKey: matchedName ?: resourceIdentityName ?: @"",
        VDTConfigTypeKey: typeValue,
        // A disabled entry resolves to zero, which the syscall layer treats as
        // "restore system defaults" rather than "apply a fatal limit".
        VDTConfigPercentageKey: percentage,
        VDTConfigIntervalKey: interval,
        VDTConfigPolicyKey: policy,
        VDTTargetStartSecondsKey: @(instanceToken.seconds),
        VDTTargetStartMicrosecondsKey: @(instanceToken.microseconds)
    } mutableCopy];

    // Bind the identity observed during resolution to the target. The syscall
    // layer re-checks it immediately before applying a CPU policy, closing the
    // exited/reused-PID window during a full process scan.
    if (executablePath) {
        target[VDTTargetExecutablePathKey] = executablePath;
    } else if (fallbackProcComm) {
        target[VDTTargetProcCommKey] = fallbackProcComm;
    } else {
        return nil;
    }
    if (memoryRule) target[VDTTargetMemoryRuleKey] = memoryRule;
    if (jetsamRule) target[VDTTargetJetsamRuleKey] = jetsamRule;
    return target;
}

NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules){
    if (configs.count == 0 && resourceRules.count == 0) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *extensionConfigsById = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *daemonConfigs = [NSMutableArray array];
    split_configs(configs, appConfigsById, extensionConfigsById, daemonConfigs);
    VDTResourceRuleMaps resourceMaps = resource_rule_maps(resourceRules);
    if (appConfigsById.count == 0 && extensionConfigsById.count == 0 && daemonConfigs.count == 0 &&
        resource_maps_empty(resourceMaps)) return @[];

    // proc_listpids reports a byte count, not an element count.
    int listBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (listBytes <= 0) return @[];

    int *buffer = (int *)malloc((size_t)listBytes);
    if (!buffer) return @[];

    int writtenBytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, listBytes);
    if (writtenBytes <= 0) {
        free(buffer);
        return @[];
    }
    if (writtenBytes > listBytes) writtenBytes = listBytes;

    int pidCount = writtenBytes / (int)sizeof(int);
    NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];

    for (int idx = 0; idx < pidCount; idx++) {
        pid_t pid = (pid_t)buffer[idx];
        if (pid <= 0) continue;
        NSDictionary *target = target_for_pid(pid, appConfigsById, extensionConfigsById, daemonConfigs, resourceMaps);
        if (target) [targets addObject:target];
    }

    free(buffer);

    VDTProbeRecord(@"runningboardd.resolveTargets", @{
        @"configCount": @(configs.count),
        @"resourceRuleCount": @(resourceRules.count),
        @"scannedPids": @(pidCount),
        @"matchedTargets": @(targets.count)
    });

    return targets;
}

NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules){
    if (pid <= 0 || (configs.count == 0 && resourceRules.count == 0)) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *appConfigsById = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *extensionConfigsById = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *daemonConfigs = [NSMutableArray array];
    split_configs(configs, appConfigsById, extensionConfigsById, daemonConfigs);
    VDTResourceRuleMaps resourceMaps = resource_rule_maps(resourceRules);

    NSDictionary *target = target_for_pid(pid, appConfigsById, extensionConfigsById, daemonConfigs, resourceMaps);
    return target ? @[target] : @[];
}

#pragma mark - Independent nice target resolution

static NSDictionary *nice_target_for_pid(pid_t pid, NSDictionary<NSString *, NSDictionary *> *rules){
    if (pid <= 1 || !rules.count) return nil;
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    NSString *path = executable_path_for_pid(pid, pathBuffer, sizeof(pathBuffer)) ?
        [NSString stringWithUTF8String:pathBuffer] : nil;
    VDTProcessInstanceToken token = {};
    if (!process_instance_token_for_pid(pid, &token)) return nil;
    NSString *extensionPath = VDTNearestBundlePath(path, @"appex");
    if (!extensionPath && path) {
        // A noncanonical/rejected appex ancestry is a blocker, not an App/daemon.
        NSString *candidate = path.stringByDeletingLastPathComponent;
        while (candidate.length > 1) {
            if ([candidate.pathExtension caseInsensitiveCompare:@"appex"] == NSOrderedSame) return nil;
            NSString *parent = candidate.stringByDeletingLastPathComponent;
            if ([candidate isEqual:parent]) break;
            candidate = parent;
        }
    }
    NSDictionary *info = extensionPath ? VDTReadExtensionBundleInfo(extensionPath, path) : nil;
    if (extensionPath && !info) return nil;
    NSString *appPath = application_bundle_path_for_executable(extensionPath ?: path);
    NSString *host = appPath ? vdt_nonEmptyString(appproxy_from_bundle_path(appPath).bundleIdentifier) : nil;
    NSString *name = nil, *comm = nil;
    VDTConfigType type = VDTConfigTypeDaemon;
    NSDictionary *rule = nil;
    if (extensionPath) {
        type = VDTConfigTypeExtension; name = info[@"extensionIdentifier"];
        if (!rules[VDTNiceRuleKey(type, name)] && !(host && rules[VDTNiceRuleKey(VDTConfigTypeApp, host)])) return nil;
        rule = VDTNiceEffectiveRuleFromRules(name, type, host, rules);
    } else if (VDTSpringBoardPathMatches(path.UTF8String) && rules[@"1:SpringBoard"]) {
        name = @VDT_SPRINGBOARD_RULE_NAME;
        rule = VDTNiceEffectiveRuleFromRules(name, type, nil, rules);
    } else if (appPath) {
        // Even an unconfigured App must not fall through to a same-name daemon.
        type = VDTConfigTypeApp; name = host;
        if (!name || !rules[VDTNiceRuleKey(type, name)]) return nil;
        rule = VDTNiceEffectiveRuleFromRules(name, type, nil, rules);
    } else {
        char executableName[PROC_PIDPATHINFO_MAXSIZE], commBuffer[256];
        BOOL hasName = path && VDTCopyLastPathComponent(path.UTF8String, executableName, sizeof(executableName));
        if (!hasName && proc_comm_for_pid(pid, commBuffer, sizeof(commBuffer)))
            comm = [NSString stringWithUTF8String:commBuffer];
        if (!hasName && !comm.length) return nil;
        for (NSDictionary *candidate in rules.allValues) {
            if ([candidate[@"type"] unsignedIntegerValue] != VDTConfigTypeDaemon) continue;
            const char *configured = [candidate[@"identifier"] UTF8String];
            if (VDTSpringBoardRuleName(configured)) {
                if (!VDTSpringBoardRuleMatches(configured, path.UTF8String)) continue;
            } else if (!VDTProcessNameMatches(configured, hasName ? executableName : NULL, comm.UTF8String)) continue;
            name = candidate[@"identifier"]; break;
        }
        if (!name) return nil;
        rule = VDTNiceEffectiveRuleFromRules(name, type, nil, rules);
    }
    if (!rule || !VDTNiceRuleKey(type, name)) return nil;
    NSMutableDictionary *target = [@{
        VDTTargetPidKey: @(pid), VDTConfigTypeKey: @(type), VDTTargetNameKey: name,
        VDTTargetStartSecondsKey: @(token.seconds), VDTTargetStartMicrosecondsKey: @(token.microseconds),
        VDTTargetNiceSourceTypeKey: rule[@"sourceType"],
        VDTTargetNiceSourceIdentifierKey: rule[@"sourceIdentifier"],
        VDTTargetNiceSourceRevisionKey: rule[@"sourceRevision"]} mutableCopy];
    if (path.length) target[VDTTargetExecutablePathKey] = path;
    else if (comm.length && type == VDTConfigTypeDaemon) target[VDTTargetProcCommKey] = comm;
    else return nil;
    if (type == VDTConfigTypeExtension && host) target[VDTTargetContainingAppIdentifierKey] = host;
    return target;
}

NSArray<NSDictionary *> *vdt_nice_targets_for_pid(pid_t pid, NSDictionary *prefs){
    return vdt_nice_targets_for_pid_from_rules(pid, VDTNiceRulesFromPrefs(prefs));
}
NSArray<NSDictionary *> *vdt_nice_resolve_targets(NSDictionary *prefs){
    return vdt_nice_resolve_targets_from_rules(VDTNiceRulesFromPrefs(prefs));
}
NSArray<NSDictionary *> *vdt_nice_targets_for_pid_from_rules(pid_t pid, NSDictionary *rules){
    NSDictionary *target = nice_target_for_pid(pid, rules);
    return target ? @[target] : @[];
}
NSArray<NSDictionary *> *vdt_nice_resolve_targets_from_rules(NSDictionary *rules){
    if (!rules.count) return @[];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return @[];
    pid_t *pids = (pid_t *)malloc((size_t)bytes);
    if (!pids) return @[];
    int written = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes);
    NSMutableArray *targets = [NSMutableArray array];
    if (written > bytes) written = bytes;
    for (int i = 0; i < written / (int)sizeof(pid_t); ++i) {
        NSDictionary *target = nice_target_for_pid(pids[i], rules);
        if (target) [targets addObject:target];
    }
    free(pids);
    return targets;
}

#pragma mark - Monitor / throttle

static BOOL target_instance_token(NSDictionary *target, VDTProcessInstanceToken *outToken){
    if (!outToken) return NO;

    NSNumber *seconds = vdt_number(target[VDTTargetStartSecondsKey]);
    NSNumber *microseconds = vdt_number(target[VDTTargetStartMicrosecondsKey]);
    if (!seconds || !microseconds) return NO;

    VDTProcessInstanceToken token = {
        .seconds = seconds.unsignedLongLongValue,
        .microseconds = microseconds.unsignedLongLongValue
    };
    if (!VDTProcessInstanceTokenIsValid(token)) return NO;

    *outToken = token;
    return YES;
}

static BOOL target_identity_is_current(NSDictionary *target, pid_t pid){
    VDTProcessInstanceToken expectedToken = {};
    VDTProcessInstanceToken beforeToken = {};
    VDTProcessInstanceToken afterToken = {};
    if (!target_instance_token(target, &expectedToken) ||
        !process_instance_token_for_pid(pid, &beforeToken) ||
        !VDTProcessInstanceMatches(expectedToken, beforeToken)) {
        return NO;
    }

    BOOL identityMatches = NO;
    NSString *expectedPath = vdt_nonEmptyString(target[VDTTargetExecutablePathKey]);
    if (expectedPath) {
        char currentPath[PROC_PIDPATHINFO_MAXSIZE];
        if (!executable_path_for_pid(pid, currentPath, sizeof(currentPath))) return NO;

        NSString *current = [NSString stringWithUTF8String:currentPath];
        identityMatches = current.length > 0 && [current isEqualToString:expectedPath];
    } else {
        NSString *expectedComm = vdt_nonEmptyString(target[VDTTargetProcCommKey]);
        if (!expectedComm) return NO;

        char currentComm[256];
        if (!proc_comm_for_pid(pid, currentComm, sizeof(currentComm))) return NO;

        NSString *current = [NSString stringWithUTF8String:currentComm];
        identityMatches = current.length > 0 && [current isEqualToString:expectedComm];
    }
    if (!identityMatches) return NO;

    // Read the lifetime token again after the path/name lookup. If the PID was
    // recycled during identity validation, the two observations cannot both
    // belong to the target instance.
    return process_instance_token_for_pid(pid, &afterToken) &&
        VDTProcessInstanceMatches(expectedToken, afterToken);
}

BOOL vdt_target_instance_is_current(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
    if (!target || !pidValue || pidValue.intValue <= 0) return NO;

    VDTProcessInstanceToken expectedToken = {};
    VDTProcessInstanceToken currentToken = {};
    return target_instance_token(target, &expectedToken) &&
        process_instance_token_for_pid((pid_t)pidValue.intValue, &currentToken) &&
        VDTProcessInstanceMatches(expectedToken, currentToken);
}

BOOL vdt_target_is_current(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
    if (!target || !pidValue || pidValue.intValue <= 0) return NO;
    return target_identity_is_current(target, (pid_t)pidValue.intValue);
}

static bool policy_identity_current(pid_t pid, void *context){
    NSDictionary *target = (__bridge NSDictionary *)context;
    return target_identity_is_current(target, pid);
}

static int policy_clear_cpu_limits(pid_t pid, void *context){
    (void)context;
    return proc_clear_cpulimits(pid);
}

static int policy_disable_cpu_monitor(pid_t pid, void *context){
    (void)context;
    return proc_disable_cpumon(pid);
}

static int policy_set_cpu_monitor_defaults(pid_t pid, void *context){
    (void)context;
    return proc_set_cpumon_defaults(pid);
}

static int policy_resume_cpu_monitor(pid_t pid, void *context){
    (void)context;
    return proc_resume_cpumon(pid);
}

static int policy_set_throttle(pid_t pid, int percentage, void *context){
    (void)context;
    return proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage);
}

static int policy_set_fatal(pid_t pid, int percentage, int interval, void *context){
    (void)context;
    return proc_set_cpumon_params_fatal(pid, percentage, interval);
}

#pragma mark - Resource stage (staged enablement)

// Production capabilities stay fully disabled until the M6 enablement step.
// The engine still builds programs and reports why nothing can be written, so
// the UI can distinguish saved from applied without faking either.
static VDTApplyCapabilities vdt_resource_capabilities(void){
    VDTApplyCapabilities capabilities = {};
    capabilities.writeMemoryCustom = false;
    capabilities.writeMemoryUnlimited = false;
    capabilities.writeJetsamBand = false;
    capabilities.restoreWriteback = false;
    return capabilities;
}

// No production syscall backend is wired yet. A NULL backend keeps the engine
// fail-closed: it reports "backend missing" instead of issuing any syscall.
static const VDTResourceBackend *vdt_resource_backend(void){
    return NULL;
}

// Applies the resolved resource rules for one target through the injectable
// backend. The stage is independent of the CPU transition in both directions:
// a CPU success never marks resource work as done, and a resource failure
// never blocks CPU protection nor erases what the CPU side achieved.
static BOOL vdt_apply_resource_target(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = target ? vdt_number(target[VDTTargetPidKey]) : nil;
    if (!target || !pidValue || pidValue.intValue <= 0) return NO;

    NSDictionary *memoryRule = vdt_dictionary(target[VDTTargetMemoryRuleKey]);
    NSDictionary *jetsamRule = vdt_dictionary(target[VDTTargetJetsamRuleKey]);
    if (!memoryRule && !jetsamRule) return YES;

    pid_t pid = (pid_t)pidValue.intValue;
    VDTMemoryRule memoryCore = {};
    VDTJetsamRule jetsamCore = {};
    if (memoryRule) {
        memoryCore = resource_memory_core_rule(memoryRule,
            (VDTPolicyRecordState)[vdt_number(memoryRule[@"state"]) unsignedLongValue]);
    }
    if (jetsamRule) {
        jetsamCore = resource_jetsam_core_rule(jetsamRule,
            (VDTPolicyRecordState)[vdt_number(jetsamRule[@"state"]) unsignedLongValue]);
    }

    // No revert records exist until the write channel is enabled, so restore
    // requirements resolve to NoWrite instead of a blind SET of defaults.
    VDTApplyProgram program = VDTApplyBuildProgram(pid,
        memoryRule ? &memoryCore : NULL,
        jetsamRule ? &jetsamCore : NULL,
        vdt_target_darwin_major(),
        false,
        false,
        vdt_resource_capabilities());

    if (program.opCount == 0) {
        VDTProbeRecord(@"runningboardd.resourceStage", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"ops": @0,
            @"memorySkip": @(program.memorySkip),
            @"jetsamSkip": @(program.jetsamSkip),
            @"writeChannel": @"disabled"
        });
        return YES;
    }

    VDTApplyTarget applyTarget = {};
    applyTarget.pid = pid;
    VDTProcessInstanceToken token = {};
    if (target_instance_token(target, &token)) {
        applyTarget.hasExpectedToken = true;
        applyTarget.expected = token;
    }

    VDTApplyReport report = VDTApplyExecute(&program, &applyTarget,
        vdt_resource_backend(), NULL);

    VDTProbeRecord(@"runningboardd.resourceStage", @{
        @"pid": @(pid),
        @"name": target[VDTTargetNameKey] ?: @"",
        @"ops": @(program.opCount),
        @"memoryOutcome": @(report.memoryOutcome),
        @"jetsamOutcome": @(report.jetsamOutcome),
        @"partial": @(report.partial),
        @"identityPreMatched": @(report.identityPreMatched),
        @"identityPostMatched": @(report.identityPostMatched),
        @"writeChannel": vdt_resource_backend() ? @"enabled" : @"disabled"
    });

    // Only a failed write stays unsettled: the next scan retries it, while a
    // disabled channel or a policy skip settles without pointless loops.
    return report.memoryOutcome != VDTApplyOutcomeFailed &&
        report.jetsamOutcome != VDTApplyOutcomeFailed;
}

BOOL vdt_apply_target(NSDictionary *rawTarget){
    NSDictionary *target = vdt_dictionary(rawTarget);
    NSNumber *pidValue = vdt_number(target[VDTTargetPidKey]);
    NSNumber *percentageValue = vdt_number(target[VDTConfigPercentageKey]);
    NSNumber *intervalValue = vdt_number(target[VDTConfigIntervalKey]);
    NSNumber *policyValue = vdt_number(target[VDTConfigPolicyKey]);
    if (!target || !pidValue || !percentageValue || !intervalValue || !policyValue) return NO;

    pid_t pid = (pid_t)pidValue.intValue;
    if (pid <= 0) return NO;

    int percentage = percentageValue.intValue;
    int interval = intervalValue.intValue;
    VDTViolationPolicy policy = (VDTViolationPolicy)policyValue.unsignedLongValue;
    VDTPolicyMode mode = VDTPolicyModeRestore;
    if (policy == VDTViolationPolicyThrottle && percentage > 0 && percentage <= UINT8_MAX) {
        mode = VDTPolicyModeThrottle;
    } else if (policy == VDTViolationPolicyMonitorAndTerminate &&
               percentage > 0 && percentage <= 100 && interval > 0) {
        mode = VDTPolicyModeFatal;
    }

    VDTPolicyOperations operations = {
        .identityCurrent = policy_identity_current,
        .clearCpuLimits = policy_clear_cpu_limits,
        .disableCpuMonitor = policy_disable_cpu_monitor,
        .setCpuMonitorDefaults = policy_set_cpu_monitor_defaults,
        .resumeCpuMonitor = policy_resume_cpu_monitor,
        .setThrottle = policy_set_throttle,
        .setFatal = policy_set_fatal,
        .context = (__bridge void *)target
    };

    errno = 0;
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        pid, mode, percentage, interval, &operations);
#if VDT_DIAGNOSTICS_ENABLED
    int operationErrno = errno;
#endif

    if (result.identityRejected) {
        VDTProbeRecord(@"runningboardd.targetSkipped", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"reason": @"identityChangedOrUnavailable"
        });
    }

    if (mode == VDTPolicyModeThrottle) {
        if (result.success) {
            HBLogDebug(@"Throttled pid %d with percentage %d%%", pid, percentage);
        }
        VDTProbeRecord(@"runningboardd.throttleSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"requestedPercentage": @(percentage),
            @"disableRet": @(result.disableResult),
            @"defaultsRet": @(result.defaultsResult),
            @"resumeRet": @(result.resumeResult),
            @"setRet": @(result.applyResult),
            @"retirementFailed": @(result.retirementFailed),
            @"identityRejected": @(result.identityRejected),
            @"errno": @(operationErrno)
        });
    } else if (mode == VDTPolicyModeFatal) {
        if (result.success) {
            HBLogDebug(@"Monitoring pid %d with percentage %d%% and interval %ds", pid, percentage, interval);
        }
        VDTProbeRecord(@"runningboardd.monitorSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"percentage": @(percentage),
            @"interval": @(interval),
            @"clearRet": @(result.clearResult),
            @"disableRet": @(result.disableResult),
            @"setRet": @(result.applyResult),
            @"resumeRet": @(result.resumeResult),
            @"retirementFailed": @(result.retirementFailed),
            @"identityRejected": @(result.identityRejected),
            @"errno": @(operationErrno)
        });
    } else {
        if (result.success) HBLogDebug(@"Restored CPU limits for pid %d", pid);
        VDTProbeRecord(@"runningboardd.restoreSyscall", @{
            @"pid": @(pid),
            @"name": target[VDTTargetNameKey] ?: @"",
            @"clearRet": @(result.clearResult),
            @"disableRet": @(result.disableResult),
            @"defaultsRet": @(result.defaultsResult),
            @"resumeRet": @(result.resumeResult),
            @"identityRejected": @(result.identityRejected),
            @"errno": @(operationErrno)
        });
    }

    // The resource stage runs regardless of the CPU outcome in either
    // direction. A CPU success must never mark memory/jetsam work as done, and
    // a resource failure must never skip CPU protection or erase its result.
    BOOL cpuApplied = result.success;
    BOOL resourceSettled = vdt_apply_resource_target(target);

    return cpuApplied && resourceSettled;
}

void vdt_apply_targets(NSArray<NSDictionary *> *targets){
    for (id target in targets) {
        vdt_apply_target(target);
    }
}
