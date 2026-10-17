//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#include <Foundation/Foundation.h>
#include <HBLog.h>
#include <objc/runtime.h>
#include <roothide.h>

#define VEDETTE_IDENTIFIER @"com.udevs.vedette"

// Runtime-resolved paths for roothide compatibility.
// jbroot() returns the original path on rootless, remapped path on roothide.
static inline NSString *VDTPrefsPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/com.udevs.vedette.plist");
    });
    return path;
}

static inline NSString *VDTPrefsPathTmp(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/tmp/com.udevs.vedette.plist");
    });
    return path;
}

#define PREFS_PATH VDTPrefsPath()
#define PREFS_PATH_TMP VDTPrefsPathTmp()

#define PROCESS_TABLE_CHANGED_NN "com.udevs.vedette.process-table-changed"
#define PREFS_CHANGED_NN @"com.udevs.vedette.prefschanged"
#define RESTORE_ALL_MONITORS_NN @"com.udevs.vedette.restore-all-monitors"

#define VDT_JBROOT_PATH(path) jbroot(@(path))
