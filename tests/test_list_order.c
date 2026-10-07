// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: MIT
#include "vedetteprefs/VDTListOrder.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static int compare_names(size_t a, size_t b, void *context) {
    const char *const *names = context;
    return strcmp(names[a], names[b]);
}

static void expect(const VDTListOrderItem *items, const char *const *names,
                   size_t count, const size_t *expected, size_t expectedCount,
                   size_t expectedEnabled) {
    size_t *order = calloc(count + 1, sizeof(*order));
    assert(order);
    order[count] = 123456; // detect output overruns, including an empty input
    size_t enabled = 999;
    size_t actual = VDTListBuildOrder(items, count, order, &enabled,
                                     compare_names, (void *)names);
    assert(actual == expectedCount);
    assert(enabled == expectedEnabled);
    for (size_t i = 0; i < actual; ++i) assert(order[i] == expected[i]);
    assert(order[count] == 123456);
    free(order);
}

static void fixtures(void) {
    VDTListOrderItem items[] = {
        {"app.alpha", false, true}, {"app.zulu", true, true},
        {"app.beta", true, true}, {"com.apple.Preferences", false, true},
        {"app.same.b", false, true}, {"app.same.a", false, true},
        {"app.beta", false, true}, {NULL, true, true}, {"", true, true}
    };
    const char *names[] = {"Alpha", "Zulu", "Beta", "Settings", "Same", "Same", "Duplicate", "Bad", "Bad"};
    const size_t initial[] = {2, 1, 0, 5, 4, 3};
    expect(items, names, 9, initial, 6, 2);
    // The kernel has no global switch input; persisted per-process state is
    // unchanged when the global switch is off. Apple identifiers are not hidden.
    expect(items, names, 9, initial, 6, 2);

    // Return from detail: a newly enabled row moves up; disabling moves it down.
    items[0].enabled = true;
    items[2].enabled = false;
    const size_t refreshed[] = {0, 1, 2, 5, 4, 3};
    expect(items, names, 9, refreshed, 6, 2);

    // One query matches across both groups. Rebuilding does not change matches.
    for (size_t i = 0; i < 9; ++i) items[i].matchesSearch = (i == 1 || i == 4 || i == 5);
    const size_t search[] = {1, 5, 4};
    expect(items, names, 9, search, 3, 1);
    items[5].enabled = true;
    const size_t searchRefreshed[] = {5, 1, 4};
    expect(items, names, 9, searchRefreshed, 3, 2);
    assert(!items[0].matchesSearch && items[1].matchesSearch);

    // Empty query result, all-enabled, all-disabled, and no initial async data.
    for (size_t i = 0; i < 9; ++i) items[i].matchesSearch = false;
    expect(items, names, 9, NULL, 0, 0);
    expect(items, names, 0, NULL, 0, 0);
    const size_t alphabetical[] = {0, 2, 5, 4, 3, 1};
    for (size_t i = 0; i < 9; ++i) items[i].matchesSearch = items[i].enabled = true;
    expect(items, names, 9, alphabetical, 6, 6);
    for (size_t i = 0; i < 9; ++i) items[i].enabled = false;
    expect(items, names, 9, alphabetical, 6, 0);

    // Canonical duplicate is selected before filtering, without renaming keys.
    VDTListOrderItem daemons[] = {
        {"same-daemon", false, false}, {"same-daemon", true, true},
        {"com.apple.example", true, true}, {"z-daemon", false, true}
    };
    const char *daemonNames[] = {"same-daemon", "same-daemon", "com.apple.example", "z-daemon"};
    const size_t daemonOrder[] = {2, 3};
    expect(daemons, daemonNames, 4, daemonOrder, 2, 1);
    assert(strcmp(daemons[2].identifier, "com.apple.example") == 0);

    size_t enabled = 1, order[1];
    assert(VDTListBuildOrder(NULL, 4, order, &enabled, NULL, NULL) == 0 && enabled == 0);
    assert(VDTListBuildOrder(items, 9, NULL, &enabled, NULL, NULL) == 0 && enabled == 0);
    assert(VDTListBuildOrder(items, 0, order, NULL, NULL, NULL) == 0);
    VDTListOrderItem identitySort[] = {{"z", false, true}, {"a", false, true}};
    size_t two[2];
    assert(VDTListBuildOrder(identitySort, 2, two, NULL, NULL, NULL) == 2);
    assert(two[0] == 1 && two[1] == 0);
}

// Independent oracle: deduplicate/filter first, then use the host qsort rather
// than the production insertion sort. Fixed-seed cases exercise ties and states.
static const VDTListOrderItem *oracleItems;
static const char *const *oracleNames;
static int oracle_compare(const void *a, const void *b) {
    size_t left = *(const size_t *)a, right = *(const size_t *)b;
    if (oracleItems[left].enabled != oracleItems[right].enabled)
        return oracleItems[left].enabled ? -1 : 1;
    int names = strcmp(oracleNames[left], oracleNames[right]);
    return names ? names : strcmp(oracleItems[left].identifier, oracleItems[right].identifier);
}

static unsigned randomState = 12345;
static unsigned next_random(void) {
    randomState = randomState * 1664525U + 1013904223U;
    return randomState;
}

static void randomized(void) {
    char identities[24][16], displayNames[8][16];
    for (size_t i = 0; i < 24; ++i) snprintf(identities[i], sizeof(identities[i]), "identity.%02zu", i);
    for (size_t i = 0; i < 8; ++i) snprintf(displayNames[i], sizeof(displayNames[i]), "name.%02zu", i);
    for (size_t iteration = 0; iteration < 1000; ++iteration) {
        VDTListOrderItem items[64];
        const char *names[64];
        size_t expected[64], count = next_random() % 65, expectedCount = 0, enabled = 0;
        bool seen[24] = {false};
        for (size_t i = 0; i < count; ++i) {
            unsigned identity = next_random() % 27;
            items[i].identifier = identity < 24 ? identities[identity] : (identity == 24 ? NULL : "");
            items[i].enabled = ((next_random() >> 8) & 1) != 0;
            items[i].matchesSearch = ((next_random() >> 8) & 1) != 0;
            names[i] = displayNames[(next_random() >> 8) % 8];
            if (identity >= 24 || seen[identity]) continue;
            seen[identity] = true;
            if (!items[i].matchesSearch) continue;
            expected[expectedCount++] = i;
            if (items[i].enabled) ++enabled;
        }
        oracleItems = items;
        oracleNames = names;
        qsort(expected, expectedCount, sizeof(*expected), oracle_compare);
        expect(items, names, count, expected, expectedCount, enabled);
    }
}

int main(void) {
    fixtures();
    randomized();
    puts("list order: fixtures + 1000 randomized production-kernel comparisons passed");
    return 0;
}
