// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
NSString *VDTNearestBundlePath(NSString *executablePath, NSString *suffix);
// nil unless .appex metadata, bundle ID and main executable are valid.
// executablePath=nil is for enumeration; a process lookup must provide its path.
// Keys: extensionIdentifier, displayName, bundlePath, executablePath,
// containingAppPath (optional). No LSPluginKitProxy private ABI required.
NSDictionary<NSString *, NSString *> *VDTReadExtensionBundleInfo(NSString *bundlePath,
                                                               NSString *executablePath);
#ifdef __cplusplus
}
#endif
