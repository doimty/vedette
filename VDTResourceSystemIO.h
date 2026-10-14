// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "VDTResourceBackend.h"
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Injectable only for host tests; production callbacks are compiled into the
// Objective-C adapter. No user preference may select a syscall or transport.
typedef struct {
    void *opaque;
    pid_t ownerPid;
    bool (*supported)(void *opaque);
    bool (*identity)(void *opaque, pid_t pid);
    bool (*token)(void *opaque, pid_t pid, VDTProcessInstanceToken *out);
    int (*control)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t bytes);
    // Numeric Jetsam semantics only: Darwin21 uses 0..21; 22+ uses 0..210.
    // Not an OS-build or hardware eligibility whitelist.
    int32_t darwinMajor;
} VDTResourceSystemIO;
const VDTResourceBackend *VDTResourceKernelBackend(void);
#ifdef __cplusplus
}
#endif
