#ifndef VDT_TEST_ROOTHIDE_H
#define VDT_TEST_ROOTHIDE_H
#import <Foundation/Foundation.h>
#include <stdlib.h>
// Test-only mapping. Never compiled into the package; all files stay in fixture root.
static inline NSString *VDTFixtureJBRoot(NSString *path) {
    const char *root = getenv("VDT_EXTENSION_FIXTURE_ROOT");
    if (!root || !root[0]) abort();
    NSString *name = [path hasPrefix:@"/var/tmp/"] ? @"temp-prefs.plist" : @"prefs.plist";
    return [[NSString stringWithUTF8String:root] stringByAppendingPathComponent:name];
}
#define jbroot(path) VDTFixtureJBRoot(path)
#endif
