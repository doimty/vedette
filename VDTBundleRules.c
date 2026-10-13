// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "VDTBundleRules.h"
#include <string.h>

VDTBundleRuleChoice VDTChooseBundleRule(bool insideApp, bool insideExtension,
    bool extensionIdentityValid, bool hasExtensionConfig, bool hasAppConfig) {
    if (insideExtension) {
        if (!extensionIdentityValid) return VDTBundleRuleNone;
        if (hasExtensionConfig) return VDTBundleRuleExtension;
        return insideApp && hasAppConfig ? VDTBundleRuleApp : VDTBundleRuleNone;
    }
    if (insideApp) return hasAppConfig ? VDTBundleRuleApp : VDTBundleRuleNone;
    return VDTBundleRuleDaemon;
}

bool VDTBundleExecutableNameIsValid(const char *name) {
    return name && name[0] && !strchr(name, '/') &&
        strcmp(name, ".") != 0 && strcmp(name, "..") != 0;
}

static unsigned char ascii_lower(unsigned char c) {
    return c >= 'A' && c <= 'Z' ? (unsigned char)(c + ('a' - 'A')) : c;
}

static bool suffix_equal(const char *value, size_t length, const char *suffix) {
    size_t wanted = strlen(suffix);
    if (length != wanted) return false;
    for (size_t i = 0; i < length; ++i) {
        if (ascii_lower((unsigned char)value[i]) != ascii_lower((unsigned char)suffix[i])) return false;
    }
    return true;
}

bool VDTCopyNearestBundlePath(const char *path, const char *suffix, char *out, size_t outSize) {
    if (out && outSize) out[0] = '\0';
    if (!path || path[0] != '/' || !suffix || !suffix[0] || !out || !outSize) return false;
    if (!suffix_equal(suffix, strlen(suffix), "app") &&
        !suffix_equal(suffix, strlen(suffix), "appex")) return false;
    size_t length = strlen(path);
    if (length < 2 || path[length - 1] == '/') return false;
    const char *last = strrchr(path, '/');
    size_t parentEnd = (size_t)(last - path);
    size_t matchedEnd = 0;
    size_t start = 1;
    for (size_t end = 1; end <= length; ++end) {
        if (end != length && path[end] != '/') continue;
        size_t componentLength = end - start;
        if (!componentLength || (componentLength == 1 && path[start] == '.') ||
            (componentLength == 2 && path[start] == '.' && path[start + 1] == '.')) return false;
        if (end <= parentEnd) {
            size_t dot = end;
            while (dot > start && path[dot - 1] != '.') --dot;
            // Require a nonempty basename before the final dot.
            if (dot > start + 1 && suffix_equal(path + dot, end - dot, suffix)) matchedEnd = end;
        }
        start = end + 1;
    }
    if (!matchedEnd || matchedEnd >= outSize) return false;
    memcpy(out, path, matchedEnd);
    out[matchedEnd] = '\0';
    return true;
}
