// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#include "VDTResourceSummary.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <limits.h>
#include <stdio.h>

static VDTResourceSummaryCounts counts(uint32_t total, uint32_t applied,
    uint32_t restored, uint32_t failed, uint32_t pending, uint32_t unknown,
    uint32_t disabled) {
    VDTResourceSummaryCounts value = {total, applied, restored, failed, pending, unknown, disabled};
    return value;
}
int main(void) {
    // All identified instances confirmed, not "partial" simply because N > 1.
    assert(VDTResourceSummaryDecide(counts(1,1,0,0,0,0,0)) == VDTResourceSummaryConfirmed);
    assert(VDTResourceSummaryDecide(counts(3,3,0,0,0,0,0)) == VDTResourceSummaryConfirmed);
    assert(VDTResourceSummaryConfirmedCount(counts(3,3,0,0,0,0,0)) == 3);
    assert(VDTResourceSummaryDecide(counts(3,0,3,0,0,0,0)) == VDTResourceSummaryRestored);
    assert(VDTResourceSummaryDecide(counts(3,2,1,0,0,0,0)) == VDTResourceSummaryConfirmed);
    // Genuine mixed outcomes preserve the successful count AND the other side.
    assert(VDTResourceSummaryDecide(counts(3,2,0,1,0,0,0)) == VDTResourceSummaryPartial);
    assert(VDTResourceSummaryConfirmedCount(counts(3,2,0,1,0,0,0)) == 2);
    assert(VDTResourceSummaryDecide(counts(3,1,0,0,2,0,0)) == VDTResourceSummaryPartial);
    assert(VDTResourceSummaryDecide(counts(3,0,1,0,0,2,0)) == VDTResourceSummaryPartial);
    assert(VDTResourceSummaryDecide(counts(3,0,0,3,0,0,0)) == VDTResourceSummaryFailed);
    assert(VDTResourceSummaryDecide(counts(3,0,0,1,1,1,0)) == VDTResourceSummaryFailed);
    assert(VDTResourceSummaryDecide(counts(3,0,0,0,3,0,0)) == VDTResourceSummaryPending);
    assert(VDTResourceSummaryDecide(counts(3,0,0,0,1,2,0)) == VDTResourceSummaryUnknown);
    assert(VDTResourceSummaryDecide(counts(3,0,0,0,0,0,3)) == VDTResourceSummaryDisabled);
    assert(VDTResourceSummaryDecide(counts(0,0,0,0,0,0,0)) == VDTResourceSummaryNoResult);
    // Denominator loss, overflow and oversized receipts never manufacture OK.
    assert(VDTResourceSummaryDecide(counts(3,2,0,0,0,0,0)) == VDTResourceSummaryInvalid);
    assert(VDTResourceSummaryDecide(counts(1,2,0,0,0,0,0)) == VDTResourceSummaryInvalid);
    assert(VDTResourceSummaryDecide(counts(0,1,0,0,0,0,0)) == VDTResourceSummaryInvalid);
    assert(VDTResourceSummaryDecide(counts(UINT32_MAX,UINT32_MAX,1,0,0,0,0)) == VDTResourceSummaryInvalid);
    assert(VDTResourceSummaryDecide(counts(65537,65537,0,0,0,0,0)) == VDTResourceSummaryInvalid);
    assert(VDTResourceSummaryConfirmedCount(counts(1,2,0,0,0,0,0)) == 0);
    // Missing from a scan, failed identity/metadata and a retained enabled rule
    // are all UNKNOWN/KEEP, not permission to restore an owned override.
    VDTResourceRestoreSelection selected = VDTResourceSelectRestores(false,true,true,
        VDTResourceIntentUnknown,VDTResourceIntentKeep);
    assert(!selected.memory && !selected.priority);
    selected = VDTResourceSelectRestores(false,true,true,VDTResourceIntentKeep,VDTResourceIntentKeep);
    assert(!selected.memory && !selected.priority);
    selected = VDTResourceSelectRestores(false,true,true,VDTResourceIntentRevoke,VDTResourceIntentKeep);
    assert(selected.memory && !selected.priority);
    selected = VDTResourceSelectRestores(false,true,true,VDTResourceIntentUnknown,VDTResourceIntentRevoke);
    assert(!selected.memory && selected.priority);
    selected = VDTResourceSelectRestores(false,false,true,VDTResourceIntentRevoke,VDTResourceIntentKeep);
    assert(!selected.memory && !selected.priority);
    // Explicit validated global off/removal is independent of scan availability,
    // but still cannot invent ownership of a side with no recovery record.
    selected = VDTResourceSelectRestores(true,true,true,VDTResourceIntentUnknown,VDTResourceIntentUnknown);
    assert(selected.memory && selected.priority);
    selected = VDTResourceSelectRestores(true,true,false,VDTResourceIntentUnknown,VDTResourceIntentUnknown);
    assert(selected.memory && !selected.priority);
    puts("PASS production resource summary counts + explicit restore authority; not device validation");
    return 0;
}
