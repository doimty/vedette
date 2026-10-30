// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#include "VDTCheckFieldLayout.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(!VDTCheckFieldNeedsVertical(320, 90, 120, 0, false, false));
    assert(!VDTCheckFieldNeedsVertical(222, 90, 120, 0, false, false));
    assert(VDTCheckFieldNeedsVertical(221, 90, 120, 0, false, false));
    assert(VDTCheckFieldNeedsVertical(230, 90, 120, 22, false, false));
    assert(VDTCheckFieldNeedsVertical(400, 90, 120, 0, true, false));
    assert(VDTCheckFieldNeedsVertical(400, 90, 120, 0, false, true));
    assert(!VDTCheckFieldNeedsVertical(0, 90, 120, 0, false, false));
    puts("PASS field layout: fitting, narrow, icons, line breaks and accessibility sizes");
    return 0;
}
