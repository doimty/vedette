// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#ifndef VDT_SPRINGBOARD_IDENTITY_H
#define VDT_SPRINGBOARD_IDENTITY_H
#include <stdbool.h>
#include <string.h>

#define VDT_SPRINGBOARD_RULE_NAME "SpringBoard"
#define VDT_SPRINGBOARD_LAUNCHD_ID "com.apple.SpringBoard"
#define VDT_SPRINGBOARD_EXECUTABLE "/System/Library/CoreServices/SpringBoard.app/SpringBoard"

// A reserved system-process identity, NOT a general .app -> daemon fallback.
// proc_pidpath supplies the canonical system path; basename/comm are not proof.
static inline bool VDTSpringBoardRuleName(const char *name) {
    return name && strcmp(name, VDT_SPRINGBOARD_RULE_NAME) == 0;
}
static inline bool VDTSpringBoardPathMatches(const char *path) {
    return path && strcmp(path, VDT_SPRINGBOARD_EXECUTABLE) == 0;
}
static inline bool VDTSpringBoardRuleMatches(const char *name, const char *path) {
    return VDTSpringBoardRuleName(name) && VDTSpringBoardPathMatches(path);
}
#endif
