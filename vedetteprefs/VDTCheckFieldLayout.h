// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#ifndef VDT_CHECK_FIELD_LAYOUT_H
#define VDT_CHECK_FIELD_LAYOUT_H
#include <stdbool.h>

// Content measurements are in points after applying the system's Dynamic Type.
// No viewport-dependent font scaling or truncation is performed here.
static inline bool VDTCheckFieldNeedsVertical(double available, double label,
    double value, double icon, bool containsNewline, bool accessibilitySize) {
    return accessibilitySize || containsNewline ||
        (available > 0 && label + value + icon + 12 > available);
}
#endif
