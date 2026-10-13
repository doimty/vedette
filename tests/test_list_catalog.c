// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#include "../vedetteprefs/VDTListCatalog.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

/* The snapshot is changed using the very same completion contract as ObjC.
 * Worker requests are serialized exactly like dispatching them onto main.
 */
static VDTListCatalogState state;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned scans;
static int snapshot;
static uint64_t start(double now, bool fallback) {
    if (VDTListCatalogEnsure(&state, now, fallback)) ++scans;
    return state.activeGeneration;
}
static VDTListCatalogCompletion finish(uint64_t generation, bool ok, int value) {
    VDTListCatalogCompletion result = VDTListCatalogComplete(&state, generation, ok);
    if (result == VDTListCatalogPublish) snapshot = value;
    return result;
}
static void *invalidate(void *unused) {
    (void)unused;
    for (int i = 0; i < 100; ++i) {
        assert(pthread_mutex_lock(&lock) == 0);
        VDTListCatalogInvalidate(&state);
        assert(!VDTListCatalogEnsure(&state, 5.0, false));
        assert(pthread_mutex_unlock(&lock) == 0);
    }
    return NULL;
}
int main(void) {
    VDTListCatalogInit(&state);
    uint64_t first = start(1, true);
    assert(scans == 1 && state.loading && !state.loaded);
    assert(!VDTListCatalogEnsure(&state, 2, true));
    assert(finish(first, true, 42) == VDTListCatalogPublish);
    for (int i = 0; i < 1000; ++i) {
        assert(!VDTListCatalogEnsure(&state, 2, true));
        assert(snapshot == 42 && state.loaded && !state.failed);
    }
    assert(scans == 1); // New instances, search and rule grouping share warm data.

    VDTListCatalogInvalidate(&state);
    uint64_t old = start(3, false);
    pthread_t workers[8];
    for (int i = 0; i < 8; ++i) assert(pthread_create(&workers[i], NULL, invalidate, NULL) == 0);
    for (int i = 0; i < 8; ++i) assert(pthread_join(workers[i], NULL) == 0);
    assert(scans == 2 && snapshot == 42);
    assert(finish(old, true, 100) == VDTListCatalogSuperseded);
    assert(snapshot == 42 && state.dirty && !state.loading);
    uint64_t newest = start(6, false);
    assert(scans == 3 && newest != old && state.loading);
    assert(finish(old, true, 999) == VDTListCatalogIgnored);
    assert(state.loading && snapshot == 42); // Old duplicate must not end new scan.
    assert(finish(newest, true, 43) == VDTListCatalogPublish);
    assert(snapshot == 43 && !state.dirty && !state.loading);

    VDTListCatalogInvalidate(&state);
    uint64_t failure = start(7, false);
    assert(finish(failure, false, 0) == VDTListCatalogFailed);
    assert(state.failed && !state.loading && state.loaded && snapshot == 43);
    assert(!VDTListCatalogEnsure(&state, 8, true)); // No failure loop on warm entry.
    assert(!VDTListCatalogEnsure(&state, 306.9, true));
    uint64_t fallback = start(307, true);
    assert(scans == 5 && state.loading && snapshot == 43);
    assert(finish(fallback, true, 44) == VDTListCatalogPublish);
    assert(!VDTListCatalogEnsure(&state, 10000, false)); // Daemon loaded gate.

    VDTListCatalogInit(&state);
    first = start(1, true);
    assert(finish(first, false, 0) == VDTListCatalogFailed);
    assert(state.failed && !state.loading && !state.loaded);
    assert(!VDTListCatalogEnsure(&state, 2, true));
    VDTListCatalogInvalidate(&state); // Explicit Retry, not pretending failure is loaded.
    first = start(3, false);
    assert(state.loading && !state.failed);
    assert(finish(first, true, 0) == VDTListCatalogPublish);
    assert(state.loaded && !state.failed); // Genuine empty snapshot is success.
    puts("PASS: production C catalog warm/generation/concurrent-invalidation/failure/retry/fallback");
    return 0;
}
