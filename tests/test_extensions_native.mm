#import <Foundation/Foundation.h>
#import "VDTBundleIdentity.h"
#import "VDTShared.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static unsigned posts;
// Compiler remaps only notification posting to this test observer; no system post.
extern "C" void VDTTestPostNotification(CFNotificationCenterRef center, CFStringRef name,
    const void *object, CFDictionaryRef info, Boolean immediately) {
    (void)center; (void)object; (void)info; (void)immediately;
    assert(CFEqual(name, CFSTR("com.udevs.vedette.prefschanged")));
    ++posts;
}

static NSDictionary *extension_info(NSString *identifier, NSString *executable) {
    return @{ @"CFBundleIdentifier": identifier, @"CFBundleExecutable": executable,
        @"CFBundleDisplayName": @"Same Name", @"NSExtension":
            @{ @"NSExtensionPointIdentifier": @"com.apple.widgetkit-extension" } };
}

int main(void) {
  @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"vdt-extension-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSFileManager *fm = NSFileManager.defaultManager;
    assert([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    assert(setenv("VDT_EXTENSION_FIXTURE_ROOT", root.UTF8String, 1) == 0);
    NSString *app = [root stringByAppendingPathComponent:@"Host.app"];
    NSString *bundle = [app stringByAppendingPathComponent:@"PlugIns/Widget.appex"];
    assert([fm createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *plist = [bundle stringByAppendingPathComponent:@"Info.plist"];
    NSString *exe = [bundle stringByAppendingPathComponent:@"Widget"];
    assert([[NSData data] writeToFile:exe atomically:YES]);
    NSDictionary *info = extension_info(@"example.host.widget", @"Widget");
    assert([info writeToFile:plist atomically:YES]);
    NSDictionary *result = VDTReadExtensionBundleInfo(bundle, exe);
    assert([result[@"extensionIdentifier"] isEqual:@"example.host.widget"]);
    assert([result[@"containingAppPath"] isEqual:app]);
    assert(VDTReadExtensionBundleInfo(bundle, nil) != nil);
    assert(VDTReadExtensionBundleInfo(bundle, [exe stringByAppendingString:@"Helper"]) == nil);
    assert([extension_info(@"example.host.widget", @"../Helper") writeToFile:plist atomically:YES]);
    assert(VDTReadExtensionBundleInfo(bundle, nil) == nil);
    NSMutableDictionary *broken = [info mutableCopy]; [broken removeObjectForKey:@"NSExtension"];
    assert([broken writeToFile:plist atomically:YES]); assert(VDTReadExtensionBundleInfo(bundle, exe) == nil);
    broken = [info mutableCopy]; broken[@"CFBundleIdentifier"] = @"";
    assert([broken writeToFile:plist atomically:YES]); assert(VDTReadExtensionBundleInfo(bundle, exe) == nil);
    broken = [info mutableCopy]; broken[@"NSExtension"] = @[];
    assert([broken writeToFile:plist atomically:YES]); assert(VDTReadExtensionBundleInfo(bundle, exe) == nil);
    assert([info writeToFile:plist atomically:YES]); assert([fm removeItemAtPath:exe error:nil]);
    assert(VDTReadExtensionBundleInfo(bundle, nil) == nil);
    assert([fm createDirectoryAtPath:exe withIntermediateDirectories:NO attributes:nil error:nil]);
    assert(VDTReadExtensionBundleInfo(bundle, nil) == nil);

    NSDictionary *appRule = @{@"bundleIdentifier": @"same.id", @"enabled": @YES, @"percentage": @80};
    NSDictionary *daemonRule = @{@"daemonName": @"same.id", @"enabled": @YES, @"percentage": @30};
    NSDictionary *base = @{@"enabled": @YES, @"appConfigs": @[appRule], @"daemonConfigs": @[daemonRule], @"sentinel": @"preserved"};
    assert([base writeToFile:PREFS_PATH atomically:YES]);
    assert(!VDTHasProcessConfig(@"same.id", VDTConfigTypeExtension, nil));
    setValueForProcessConfigKey(@"same.id", @"enabled", @NO, VDTConfigTypeExtension);
    assert(posts == 1 && VDTHasProcessConfig(@"same.id", VDTConfigTypeExtension, nil));
    NSDictionary *prefs = getPrefs();
    assert([prefs[@"appConfigs"] isEqual:base[@"appConfigs"]]);
    assert([prefs[@"daemonConfigs"] isEqual:base[@"daemonConfigs"]]);
    assert([valueForProcessConfigKey(@"same.id", @"enabled", @YES, VDTConfigTypeExtension) isEqual:@NO]);
    assert([valueForProcessConfigKey(@"same.id", @"percentage", nil, VDTConfigTypeApp) isEqual:@80]);
    setValueForProcessConfigKey(@"other.extension", @"percentage", @12, VDTConfigTypeExtension);
    assert(posts == 2 && !VDTHasProcessConfig(@"unknown", VDTConfigTypeExtension, nil));
    NSDictionary *beforeUnknown = getPrefs();
    setValueForProcessConfigKey(@"bad.type", @"enabled", @YES, (VDTConfigType)999);
    assert(posts == 2 && [getPrefs() isEqual:beforeUnknown]);
    assert([valueForProcessConfigKey(@"same.id", @"enabled", @"fallback", (VDTConfigType)999) isEqual:@"fallback"]);
    NSMutableDictionary *duplicates = [getPrefs() mutableCopy];
    NSMutableArray *entries = [duplicates[@"extensionConfigs"] mutableCopy];
    [entries addObject:@{@"extensionIdentifier": @"same.id", @"enabled": @YES}];
    duplicates[@"extensionConfigs"] = entries;
    assert([duplicates writeToFile:PREFS_PATH atomically:YES]);
    assert([valueForProcessConfigKey(@"same.id", @"enabled", nil, VDTConfigTypeExtension) isEqual:@NO]);
    VDTRemoveProcessConfig(@"same.id", VDTConfigTypeExtension);
    assert(posts == 3 && !VDTHasProcessConfig(@"same.id", VDTConfigTypeExtension, nil));
    assert(VDTHasProcessConfig(@"other.extension", VDTConfigTypeExtension, nil));
    VDTRemoveProcessConfig(@"same.id", VDTConfigTypeExtension); assert(posts == 3);
    prefs = getPrefs();
    assert([prefs[@"appConfigs"] isEqual:base[@"appConfigs"]]);
    assert([prefs[@"daemonConfigs"] isEqual:base[@"daemonConfigs"]]);
    assert([prefs[@"sentinel"] isEqual:base[@"sentinel"]]);
    assert([fm removeItemAtPath:root error:nil]);
    puts("PASS: production Foundation extension metadata, isolated rules, duplicates, inheritance removal, notifications");
  }
  return 0;
}
