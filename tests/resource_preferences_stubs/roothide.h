#ifndef VDT_RESOURCE_PREFS_TEST_ROOTHIDE_H
#define VDT_RESOURCE_PREFS_TEST_ROOTHIDE_H
#import <Foundation/Foundation.h>
#include <stdlib.h>
// Only test compiler include paths see this file. Never maps to a device plist.
static inline NSString *VDTResourceFixturePath(NSString *path) {
    const char *root = getenv("VDT_RESOURCE_PREFS_FIXTURE_ROOT");
    if (!root || !root[0]) abort();
    NSString *name = [path hasPrefix:@"/var/tmp/"] ? @"temp-prefs.plist" : @"prefs.plist";
    return [[NSString stringWithUTF8String:root] stringByAppendingPathComponent:name];
}
#define jbroot(path) VDTResourceFixturePath(path)
#endif
