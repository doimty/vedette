// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef VDTBundleRules_h
#define VDTBundleRules_h
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    VDTBundleRuleNone = 0,
    VDTBundleRuleApp,
    VDTBundleRuleExtension,
    VDTBundleRuleDaemon
} VDTBundleRuleChoice;

// Only the main executable of a validated extension has an extension identity.
// A present disabled/malformed extension config is still an explicit override.
VDTBundleRuleChoice VDTChooseBundleRule(bool insideApp, bool insideExtension,
    bool extensionIdentityValid, bool hasExtensionConfig, bool hasAppConfig);

// Copies the nearest enclosing .app/.appex directory, excluding the executable
// basename. Requires an absolute canonical component path, rejects . and ..,
// and never returns a partial path. suffix is "app" or "appex" (case-insensitive).
bool VDTCopyNearestBundlePath(const char *executablePath, const char *suffix,
    char *out, size_t outSize);
bool VDTBundleExecutableNameIsValid(const char *name);

#ifdef __cplusplus
}
#endif
#endif
