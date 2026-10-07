// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: MIT

#ifndef VDT_LIST_ORDER_H
#define VDT_LIST_ORDER_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    const char *identifier; // Original configuration identity, not the display name.
    bool enabled;          // Saved per-process switch only; no global/runtime state.
    bool matchesSearch;
} VDTListOrderItem;

typedef int (*VDTListNameCompare)(size_t left, size_t right, void *context);

// Writes source indices to `order` (capacity >= count). First occurrence of each
// nonempty identity wins, even if it does not match the query. The caller owns
// strings and supplies its platform's localized display-name comparator. Equal
// names are ordered by original identity so different same-named apps survive.
// Header-only: the Preferences target and host tests execute this exact kernel.
static inline size_t VDTListBuildOrder(const VDTListOrderItem *items, size_t count,
                                      size_t *order, size_t *enabledCount,
                                      VDTListNameCompare compare, void *context) {
    size_t written = 0;
    if (enabledCount) *enabledCount = 0;
    if (!items || !order) return 0;
    for (size_t i = 0; i < count; ++i) {
        const char *identifier = items[i].identifier;
        if (!identifier || !identifier[0]) continue;
        bool duplicate = false;
        for (size_t j = 0; j < i; ++j) {
            if (items[j].identifier && strcmp(identifier, items[j].identifier) == 0) {
                duplicate = true;
                break;
            }
        }
        if (duplicate || !items[i].matchesSearch) continue;
        size_t position = written;
        while (position > 0) {
            size_t previous = order[position - 1];
            int comparison;
            if (items[i].enabled != items[previous].enabled) {
                comparison = items[i].enabled ? -1 : 1;
            } else {
                comparison = compare ? compare(i, previous, context) : 0;
                if (comparison == 0) comparison = strcmp(identifier, items[previous].identifier);
            }
            if (comparison >= 0) break;
            order[position] = previous;
            --position;
        }
        order[position] = i;
        ++written;
        if (items[i].enabled && enabledCount) ++*enabledCount;
    }
    return written;
}

#endif
