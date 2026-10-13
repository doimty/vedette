// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef VDT_LIST_CATALOG_H
#define VDT_LIST_CATALOG_H
#include <stdbool.h>
#include <stdint.h>

/* Caller serializes every transition (production: main queue). No PID or UI.
 * One active scan; invalidations during it coalesce into one newer scan.
 * A failed attempt is sticky until explicit invalidation or the bounded entry
 * fallback. Snapshot ownership is outside this kernel and changes ONLY on
 * VDTListCatalogPublish. Header-only so existing .m wildcard builds include it.
 */
#define VDT_LIST_CATALOG_FALLBACK_SECONDS 300.0

typedef struct {
    uint64_t generation;
    uint64_t activeGeneration;
    bool loaded;
    bool loading;
    bool failed;
    bool dirty;
    bool attempted;
    double lastAttempt;
} VDTListCatalogState;

typedef enum {
    VDTListCatalogIgnored,
    VDTListCatalogSuperseded,
    VDTListCatalogFailed,
    VDTListCatalogPublish
} VDTListCatalogCompletion;

static inline void VDTListCatalogInit(VDTListCatalogState *state) {
    *state = (VDTListCatalogState){.generation = 1, .activeGeneration = 0,
        .loaded = false, .loading = false, .failed = false, .dirty = true,
        .attempted = false, .lastAttempt = 0};
}

static inline void VDTListCatalogInvalidate(VDTListCatalogState *state) {
    ++state->generation;
    state->dirty = true;
    /* Preserve loaded/snapshot; a pending refresh is not a successful scan. */
}

/* fallback is only evaluated on ensure/entry, never an unbounded timer. */
static inline bool VDTListCatalogEnsure(VDTListCatalogState *state,
                                         double now, bool fallback) {
    if (state->loading) return false;
    if (!state->dirty && fallback && state->attempted &&
        now - state->lastAttempt >= VDT_LIST_CATALOG_FALLBACK_SECONDS)
        VDTListCatalogInvalidate(state);
    if (!state->dirty) return false;
    state->loading = true;
    state->failed = false;
    state->attempted = true;
    state->lastAttempt = now;
    state->activeGeneration = state->generation;
    return true;
}

static inline VDTListCatalogCompletion VDTListCatalogComplete(
        VDTListCatalogState *state, uint64_t generation, bool success) {
    if (!state->loading || generation != state->activeGeneration)
        return VDTListCatalogIgnored;
    state->loading = false;
    state->activeGeneration = 0;
    if (generation != state->generation) return VDTListCatalogSuperseded;
    state->dirty = false;
    state->failed = !success;
    if (!success) return VDTListCatalogFailed;
    state->loaded = true;
    return VDTListCatalogPublish;
}
#endif
